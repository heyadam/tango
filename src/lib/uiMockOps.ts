// Pure, in-place-free mutations for the UI mock spec. This is the single
// source of truth for node-level edits, shared by BOTH surfaces:
//   - server: uiMockBridge wrappers apply an op to the live cache then
//     re-broadcast the whole spec (see uiMockBridge.ts).
//   - browser: UIMockCanvas calls these inside setSpec(prev => op(prev, …)).
// Every function returns a NEW spec (never mutates its input) so React's
// setSpec sees a fresh reference and the server cache stays referentially
// honest. Validation collects ALL problems before throwing, so callers get
// one useful error instead of a fix-one-retry loop.

import type {
  UIComponent,
  UIDesignSystem,
  UIGroup,
  UINode,
  UIScreen,
  UISpec,
} from './uiMockProtocol';

export type ReorderOp = 'front' | 'back' | 'forward' | 'backward';

// Patch shape for updateNodeInSpec — every field except `id` (which is
// immutable; a node's identity can't change under it). Aligned with the
// `uiNodePatchSchema` Zod shape in mcp.ts.
export type NodePatch = Partial<Omit<UINode, 'id'>>;

export type LayerInfo = {
  // Array index of the node within its screen. Higher z = rendered on top
  // (later siblings paint over earlier ones).
  z: number;
  id: string;
  type: UINode['type'];
  text?: string;
  // Editor-level group membership (id into the screen's `groups`).
  group?: string;
  rect: { x: number; y: number; width: number; height: number };
};

export type ScreenLayers = {
  id: string;
  title: string;
  frame: { w: number; h: number };
  sourceFile?: string;
  groups?: UIGroup[];
  layers: LayerInfo[];
};

export type LayersOutline = { screens: ScreenLayers[] };

// Find one node by id across all screens (null when absent). The canvas and
// its gesture/draw hooks share this for ref-based lookups.
export function findNodeInSpec(spec: UISpec, id: string): UINode | null {
  for (const screen of spec.screens) {
    for (const node of screen.nodes) {
      if (node.id === id) return node;
    }
  }
  return null;
}

function collectIds(spec: UISpec): Set<string> {
  const ids = new Set<string>();
  for (const screen of spec.screens) {
    for (const node of screen.nodes) ids.add(node.id);
  }
  return ids;
}

function fail(errors: string[]): never {
  throw new Error(
    errors.length === 1
      ? errors[0]
      : `${errors.length} errors:\n - ${errors.join('\n - ')}`,
  );
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

// Append node(s) to a screen. New nodes land at the END of the screen's node
// array — i.e. on TOP of the z-order. Errors (collected): unknown screen id,
// a node id duplicated within the incoming batch, or a node id that already
// exists anywhere in the spec (node ids are globally unique).
export function addNodesToScreen(
  spec: UISpec,
  screenId: string,
  nodes: UINode[],
): UISpec {
  const errors: string[] = [];
  const screen = spec.screens.find((s) => s.id === screenId);
  if (!screen) errors.push(`Unknown screen id: ${screenId}`);
  const existing = collectIds(spec);
  const batchSeen = new Set<string>();
  for (const node of nodes) {
    if (batchSeen.has(node.id)) {
      errors.push(`Duplicate node id within batch: ${node.id}`);
    }
    batchSeen.add(node.id);
    if (existing.has(node.id)) {
      errors.push(`Node id already exists in the mock: ${node.id}`);
    }
  }
  if (errors.length) fail(errors);
  return {
    ...spec,
    screens: spec.screens.map((s) =>
      s.id === screenId ? { ...s, nodes: [...s.nodes, ...nodes] } : s,
    ),
  };
}

// Append one screen to the spec. Errors (collected): a screen id that already
// exists, a node id duplicated within the incoming screen, or a node id that
// already exists anywhere in the spec (node ids are globally unique).
// Pre-existing screens keep object identity.
export function appendScreenToSpec(spec: UISpec, screen: UIScreen): UISpec {
  const errors: string[] = [];
  if (spec.screens.some((s) => s.id === screen.id)) {
    errors.push(`Screen id already exists: ${screen.id}`);
  }
  const existing = collectIds(spec);
  const screenSeen = new Set<string>();
  for (const node of screen.nodes) {
    if (screenSeen.has(node.id)) {
      errors.push(`Duplicate node id within screen: ${node.id}`);
    }
    screenSeen.add(node.id);
    if (existing.has(node.id)) {
      errors.push(`Node id already exists in the mock: ${node.id}`);
    }
  }
  if (errors.length) fail(errors);
  return { ...spec, screens: [...spec.screens, screen] };
}

// Duplicate one screen as a new screen appended at the end — the cheap first
// step of a variation (duplicate, then patch deltas with updateNodesInSpec).
// Node ids are remapped onto the new screen id: a `<sourceId>-` prefix is
// swapped for `<newId>-`, anything else gets `<newId>-` prepended. sourceFile
// (and sourceHash) is NOT copied (a duplicate doesn't mirror the original's
// source file).
// Errors (collected): unknown source screen, newScreenId already taken, any
// remapped node id colliding globally or within the duplicate.
export function duplicateScreenInSpec(
  spec: UISpec,
  sourceScreenId: string,
  newScreenId: string,
  newTitle?: string,
): UISpec {
  const errors: string[] = [];
  const source = spec.screens.find((s) => s.id === sourceScreenId);
  if (!source) errors.push(`Unknown screen id: ${sourceScreenId}`);
  if (spec.screens.some((s) => s.id === newScreenId)) {
    errors.push(`Screen id already exists: ${newScreenId}`);
  }
  if (errors.length) fail(errors);
  const existing = collectIds(spec);
  const remapped = new Set<string>();
  const prefix = `${sourceScreenId}-`;
  const nodes = source!.nodes.map((node) => {
    const id = node.id.startsWith(prefix)
      ? `${newScreenId}-${node.id.slice(prefix.length)}`
      : `${newScreenId}-${node.id}`;
    if (remapped.has(id)) {
      errors.push(`Duplicate node id within duplicated screen: ${id}`);
    }
    remapped.add(id);
    if (existing.has(id)) {
      errors.push(`Node id already exists in the mock: ${id}`);
    }
    return { ...node, id };
  });
  if (errors.length) fail(errors);
  const { sourceFile: _dropped, sourceHash: _droppedHash, ...rest } = source!;
  const screen: UIScreen = {
    ...rest,
    id: newScreenId,
    title: newTitle ?? `${source!.title} copy`,
    nodes,
  };
  return { ...spec, screens: [...spec.screens, screen] };
}

// Remove one screen (and all its nodes) by id. Errors if the screen doesn't
// exist. Remaining screens keep object identity.
export function removeScreenFromSpec(spec: UISpec, screenId: string): UISpec {
  if (!spec.screens.some((s) => s.id === screenId)) {
    fail([`Unknown screen id: ${screenId}`]);
  }
  return { ...spec, screens: spec.screens.filter((s) => s.id !== screenId) };
}

// Shallow-merge a patch into a single node, found by id across all screens.
// `id` is never changed even if present on the patch object. Errors if the
// node doesn't exist.
export function updateNodeInSpec(
  spec: UISpec,
  nodeId: string,
  patch: NodePatch,
): UISpec {
  let found = false;
  const screens = spec.screens.map((screen) => ({
    ...screen,
    nodes: screen.nodes.map((node) => {
      if (node.id !== nodeId) return node;
      found = true;
      return { ...node, ...patch, id: node.id };
    }),
  }));
  if (!found) fail([`Unknown node id: ${nodeId}`]);
  return { ...spec, screens };
}

// Bulk node patches in one call — the delta path for restyles (one tool call,
// many small patches, instead of regenerating nodes or N round-trips).
// All-or-nothing: unknown ids are collected and thrown before any mutation.
// Multiple patches to the same node merge in order. Untouched screens and
// nodes keep object identity (the React.memo contract).
export function updateNodesInSpec(
  spec: UISpec,
  patches: Array<{ nodeId: string; patch: NodePatch }>,
): UISpec {
  const existing = collectIds(spec);
  const missing = [
    ...new Set(patches.filter((p) => !existing.has(p.nodeId)).map((p) => p.nodeId)),
  ];
  if (missing.length) fail(missing.map((id) => `Unknown node id: ${id}`));
  const merged = new Map<string, NodePatch>();
  for (const { nodeId, patch } of patches) {
    merged.set(nodeId, { ...merged.get(nodeId), ...patch });
  }
  return {
    ...spec,
    screens: spec.screens.map((screen) => {
      if (!screen.nodes.some((n) => merged.has(n.id))) return screen;
      return {
        ...screen,
        nodes: screen.nodes.map((node) => {
          const patch = merged.get(node.id);
          return patch ? { ...node, ...patch, id: node.id } : node;
        }),
      };
    }),
  };
}

// Patch screen-level fields (title, frame). The id is immutable — export
// filenames and the preview's show_screen are keyed on it. Nodes keep object
// identity; other screens keep screen identity.
export function updateScreenInSpec(
  spec: UISpec,
  screenId: string,
  patch: { title?: string; frame?: { w: number; h: number } },
): UISpec {
  if (!spec.screens.some((s) => s.id === screenId)) {
    fail([`Unknown screen id: ${screenId}`]);
  }
  return {
    ...spec,
    screens: spec.screens.map((s) =>
      s.id === screenId
        ? {
            ...s,
            ...(patch.title !== undefined ? { title: patch.title } : {}),
            ...(patch.frame !== undefined ? { frame: patch.frame } : {}),
          }
        : s,
    ),
  };
}

// Remove node(s) by id. All-or-nothing: if ANY id is missing, throws and
// performs no mutation, so a typo can't silently drop the wrong subset.
export function removeNodesFromSpec(spec: UISpec, nodeIds: string[]): UISpec {
  const existing = collectIds(spec);
  const missing = nodeIds.filter((id) => !existing.has(id));
  if (missing.length) {
    fail(missing.map((id) => `Unknown node id: ${id}`));
  }
  const toDrop = new Set(nodeIds);
  return {
    ...spec,
    screens: spec.screens.map((screen) =>
      pruneScreenGroups({
        ...screen,
        nodes: screen.nodes.filter((node) => !toDrop.has(node.id)),
      }),
    ),
  };
}

// Change a node's z-order within its own screen, group-aware so a step can
// never fracture a z-contiguous group block:
//   - A node WITH a live group tag moves within its own block only:
//     `forward`/`backward` step one slot clamped at the block edges (a step
//     at an edge is a no-op that still returns a fresh spec); `front`/`back`
//     jump to the top/bottom OF THE BLOCK, not the array.
//   - A node WITHOUT a group tag (an orphan tag — no registry entry — counts
//     as ungrouped, matching the layers tree): `forward`/`backward` swap with
//     the adjacent sibling, except when that sibling is a group member — then
//     the node jumps past that ENTIRE contiguous block (exactly one block per
//     call, so adjacent blocks take one keypress each); `front`/`back` go to
//     the array extremes. Moves at a boundary are a no-op (fresh spec).
// The landed screen runs through normalizeScreenGroups as a backstop (a
// no-op when the stepping math above holds).
export function reorderNodeInSpec(
  spec: UISpec,
  nodeId: string,
  op: ReorderOp,
): UISpec {
  const screenIdx = spec.screens.findIndex((s) =>
    s.nodes.some((n) => n.id === nodeId),
  );
  if (screenIdx === -1) fail([`Unknown node id: ${nodeId}`]);
  const screen = spec.screens[screenIdx];
  const idx = screen.nodes.findIndex((n) => n.id === nodeId);
  const liveIds = new Set((screen.groups ?? []).map((g) => g.id));
  const liveGroupOf = (n: UINode) =>
    n.group !== undefined && liveIds.has(n.group) ? n.group : undefined;
  const own = liveGroupOf(screen.nodes[idx]);

  // Target index in the array AFTER the node is removed from its old slot
  // (the same convention the splice below uses).
  let target: number;
  if (own !== undefined) {
    // Members are z-contiguous: clamp every op to the node's own block.
    let blockStart = idx;
    while (blockStart > 0 && screen.nodes[blockStart - 1].group === own) {
      blockStart -= 1;
    }
    let blockEnd = idx;
    while (
      blockEnd < screen.nodes.length - 1 &&
      screen.nodes[blockEnd + 1].group === own
    ) {
      blockEnd += 1;
    }
    switch (op) {
      case 'front':
        target = blockEnd;
        break;
      case 'back':
        target = blockStart;
        break;
      case 'forward':
        target = Math.min(blockEnd, idx + 1);
        break;
      case 'backward':
        target = Math.max(blockStart, idx - 1);
        break;
    }
  } else {
    switch (op) {
      case 'front':
        target = screen.nodes.length - 1;
        break;
      case 'back':
        target = 0;
        break;
      case 'forward': {
        const above =
          idx < screen.nodes.length - 1
            ? liveGroupOf(screen.nodes[idx + 1])
            : undefined;
        if (above !== undefined) {
          // Jump past the whole contiguous block above (land just above it).
          let j = idx + 1;
          while (
            j < screen.nodes.length - 1 &&
            screen.nodes[j + 1].group === above
          ) {
            j += 1;
          }
          target = j;
        } else {
          target = Math.min(screen.nodes.length - 1, idx + 1);
        }
        break;
      }
      case 'backward': {
        const below = idx > 0 ? liveGroupOf(screen.nodes[idx - 1]) : undefined;
        if (below !== undefined) {
          // Jump below the whole contiguous block beneath.
          let j = idx - 1;
          while (j > 0 && screen.nodes[j - 1].group === below) {
            j -= 1;
          }
          target = j;
        } else {
          target = Math.max(0, idx - 1);
        }
        break;
      }
    }
  }
  const nodes = [...screen.nodes];
  const [node] = nodes.splice(idx, 1);
  nodes.splice(target, 0, node);
  const nextScreen = normalizeScreenGroups({ ...screen, nodes });
  return {
    ...spec,
    screens: spec.screens.map((s, i) => (i === screenIdx ? nextScreen : s)),
  };
}

// ── groups ─────────────────────────────────────────────────────────────────
// Editor-level grouping: membership = `node.group` (a registry id), names =
// `screen.groups`. Groups are organization/selection aids only — the node
// list stays flat and rendering/export never consult them. Invariants kept
// here: members of a group are z-contiguous (enforced at group time), every
// `node.group` points at a live registry entry, and empty groups are pruned.

// Drop registry entries with no members and tags with no registry entry.
// Returns the SAME screen reference when nothing changed (memo contract).
function pruneScreenGroups(screen: UIScreen): UIScreen {
  const groups = screen.groups ?? [];
  const memberCounts = new Map<string, number>();
  for (const node of screen.nodes) {
    if (node.group) {
      memberCounts.set(node.group, (memberCounts.get(node.group) ?? 0) + 1);
    }
  }
  const liveGroups = groups.filter((g) => (memberCounts.get(g.id) ?? 0) > 0);
  const liveIds = new Set(liveGroups.map((g) => g.id));
  const orphanTags = screen.nodes.some(
    (n) => n.group !== undefined && !liveIds.has(n.group),
  );
  if (liveGroups.length === groups.length && !orphanTags) return screen;
  const next: UIScreen = {
    ...screen,
    nodes: orphanTags
      ? screen.nodes.map((n) =>
          n.group !== undefined && !liveIds.has(n.group)
            ? stripGroupTag(n)
            : n,
        )
      : screen.nodes,
  };
  if (liveGroups.length > 0) next.groups = liveGroups;
  else delete next.groups;
  return next;
}

function stripGroupTag(node: UINode): UINode {
  const { group: _dropped, ...rest } = node;
  return rest;
}

// Smallest `group-N` id not yet taken within the screen, with `Group N` name.
function freshGroupId(screen: UIScreen): { id: string; name: string } {
  const taken = new Set((screen.groups ?? []).map((g) => g.id));
  let n = 1;
  while (taken.has(`group-${n}`)) n += 1;
  return { id: `group-${n}`, name: `Group ${n}` };
}

// Repair the group invariants on one screen: orphan tags stripped and empty
// registry entries pruned (pruneScreenGroups), then every group whose members
// are fractured in z is re-coalesced — members come out (preserving relative
// order) and reinsert as one block anchored where the TOPMOST member sat
// among the non-members (the same policy as groupNodesInSpec). Groups are
// processed in registry order. Returns the SAME screen reference when nothing
// changed (memo contract).
export function normalizeScreenGroups(screen: UIScreen): UIScreen {
  let next = pruneScreenGroups(screen);
  for (const group of next.groups ?? []) {
    let first = -1;
    let last = -1;
    let count = 0;
    for (let i = 0; i < next.nodes.length; i += 1) {
      if (next.nodes[i].group !== group.id) continue;
      if (first === -1) first = i;
      last = i;
      count += 1;
    }
    if (last - first === count - 1) continue;
    const members: UINode[] = [];
    const rest: UINode[] = [];
    let insertAt = 0;
    for (const node of next.nodes) {
      if (node.group === group.id) {
        members.push(node);
        insertAt = rest.length;
      } else {
        rest.push(node);
      }
    }
    next = {
      ...next,
      nodes: [...rest.slice(0, insertAt), ...members, ...rest.slice(insertAt)],
    };
  }
  return next;
}

// Group nodes on one screen. Members are re-tagged (leaving any previous
// group, which is pruned if emptied) and made z-contiguous: the block is
// reinserted where the topmost member sat, preserving the members' relative
// order. Errors (collected): unknown screen, empty nodeIds, ids not on that
// screen, explicit id already taken.
export function groupNodesInSpec(
  spec: UISpec,
  screenId: string,
  nodeIds: string[],
  opts?: { id?: string; name?: string },
): UISpec {
  const errors: string[] = [];
  const screen = spec.screens.find((s) => s.id === screenId);
  if (!screen) fail([`Unknown screen id: ${screenId}`]);
  if (nodeIds.length === 0) errors.push('groupNodes requires at least one node id');
  const onScreen = new Set(screen!.nodes.map((n) => n.id));
  for (const id of nodeIds) {
    if (!onScreen.has(id)) errors.push(`Node not on screen ${screenId}: ${id}`);
  }
  if (opts?.id && (screen!.groups ?? []).some((g) => g.id === opts.id)) {
    errors.push(`Group id already exists on screen: ${opts.id}`);
  }
  if (errors.length) fail(errors);

  const fresh = freshGroupId(screen!);
  const groupId = opts?.id ?? fresh.id;
  const name = opts?.name ?? fresh.name;
  const memberSet = new Set(nodeIds);

  // Contiguity: pull members out (preserving relative order), reinsert as a
  // block at the index the topmost member occupied among non-members.
  const members: UINode[] = [];
  const rest: UINode[] = [];
  let insertAt = 0;
  for (const node of screen!.nodes) {
    if (memberSet.has(node.id)) {
      members.push({ ...node, group: groupId });
      // The block lands where the topmost member sat: count the non-members
      // BELOW it (rest.length at that moment).
      insertAt = rest.length;
    } else {
      rest.push(node);
    }
  }
  const nodes = [...rest.slice(0, insertAt), ...members, ...rest.slice(insertAt)];

  const groups = [...(screen!.groups ?? []), { id: groupId, name }];
  const nextScreen = pruneScreenGroups({ ...screen!, nodes, groups });
  return {
    ...spec,
    screens: spec.screens.map((s) => (s.id === screenId ? nextScreen : s)),
  };
}

// Dissolve a group: members lose their tag (staying exactly where they are in
// z), the registry entry goes away. Group ids are only unique PER SCREEN
// ('group-1' exists on every screen that ever grouped) — `screenId` pins
// resolution to that one screen (throwing when it has no such group);
// omitted, the first screen with the id wins. Errors if no screen has the
// group.
export function ungroupNodesInSpec(
  spec: UISpec,
  groupId: string,
  screenId?: string,
): UISpec {
  const screen = spec.screens.find(
    (s) =>
      (screenId === undefined || s.id === screenId) &&
      (s.groups ?? []).some((g) => g.id === groupId),
  );
  if (!screen) {
    fail([
      screenId === undefined
        ? `Unknown group id: ${groupId}`
        : `Unknown group id on screen ${screenId}: ${groupId}`,
    ]);
  }
  const nextScreen: UIScreen = {
    ...screen,
    nodes: screen.nodes.map((n) => (n.group === groupId ? stripGroupTag(n) : n)),
  };
  const remaining = (screen.groups ?? []).filter((g) => g.id !== groupId);
  if (remaining.length > 0) nextScreen.groups = remaining;
  else delete nextScreen.groups;
  return {
    ...spec,
    screens: spec.screens.map((s) => (s.id === screen.id ? nextScreen : s)),
  };
}

// Rename a group's registry entry. Same id-collision caveat as ungroup:
// `screenId` pins resolution to that one screen (throwing when it has no
// such group); omitted, the first screen with the id wins.
export function renameGroupInSpec(
  spec: UISpec,
  groupId: string,
  name: string,
  screenId?: string,
): UISpec {
  if (!name.trim()) fail(['Group name must not be empty']);
  const screen = spec.screens.find(
    (s) =>
      (screenId === undefined || s.id === screenId) &&
      (s.groups ?? []).some((g) => g.id === groupId),
  );
  if (!screen) {
    fail([
      screenId === undefined
        ? `Unknown group id: ${groupId}`
        : `Unknown group id on screen ${screenId}: ${groupId}`,
    ]);
  }
  return {
    ...spec,
    screens: spec.screens.map((s) =>
      s.id === screen.id
        ? {
            ...s,
            groups: (s.groups ?? []).map((g) =>
              g.id === groupId ? { ...g, name: name.trim() } : g,
            ),
          }
        : s,
    ),
  };
}

// Move a node to an explicit z-index, optionally joining a group (string),
// leaving one (null), or keeping membership (undefined), and optionally onto
// another screen. The layers tree's drag-reorder commits through this so a
// drop is one atomic spec change. targetIndex is clamped; the index is
// interpreted AFTER the node is removed from its old slot. Empty groups are
// pruned, and the landed screen is ALWAYS normalized (normalizeScreenGroups):
// a landing index interior to ANY group's block — the joined group or an
// uninvolved one — effectively snaps to that block's boundary instead of
// fracturing it; callers' index math can race concurrent edits and must not
// be able to fracture a group. Cross-screen (targetScreenId set and different
// from the node's own screen): `group` must name a group on the TARGET
// screen, otherwise the tag is stripped (a tag from the old screen must never
// travel), and x/y clamp so the box stays inside the target frame (origin 0
// when it can't fit).
export function moveNodeInSpec(
  spec: UISpec,
  nodeId: string,
  targetIndex: number,
  group?: string | null,
  targetScreenId?: string,
): UISpec {
  const screenIdx = spec.screens.findIndex((s) =>
    s.nodes.some((n) => n.id === nodeId),
  );
  if (screenIdx === -1) fail([`Unknown node id: ${nodeId}`]);
  const screen = spec.screens[screenIdx];

  if (targetScreenId !== undefined && targetScreenId !== screen.id) {
    const targetIdx = spec.screens.findIndex((s) => s.id === targetScreenId);
    if (targetIdx === -1) fail([`Unknown screen id: ${targetScreenId}`]);
    const targetScreen = spec.screens[targetIdx];
    if (
      typeof group === 'string' &&
      !(targetScreen.groups ?? []).some((g) => g.id === group)
    ) {
      fail([`Unknown group id on screen ${targetScreen.id}: ${group}`]);
    }
    let node = screen.nodes.find((n) => n.id === nodeId)!;
    node =
      typeof group === 'string' ? { ...node, group } : stripGroupTag(node);
    node = {
      ...node,
      x: Math.max(0, Math.min(node.x, targetScreen.frame.w - node.width)),
      y: Math.max(0, Math.min(node.y, targetScreen.frame.h - node.height)),
    };
    const source = pruneScreenGroups({
      ...screen,
      nodes: screen.nodes.filter((n) => n.id !== nodeId),
    });
    const nodes = [...targetScreen.nodes];
    const target = Math.max(0, Math.min(nodes.length, Math.round(targetIndex)));
    nodes.splice(target, 0, node);
    const nextTarget = normalizeScreenGroups({ ...targetScreen, nodes });
    return {
      ...spec,
      screens: spec.screens.map((s, i) =>
        i === screenIdx ? source : i === targetIdx ? nextTarget : s,
      ),
    };
  }

  if (
    typeof group === 'string' &&
    !(screen.groups ?? []).some((g) => g.id === group)
  ) {
    fail([`Unknown group id on screen ${screen.id}: ${group}`]);
  }
  const idx = screen.nodes.findIndex((n) => n.id === nodeId);
  const nodes = [...screen.nodes];
  let [node] = nodes.splice(idx, 1);
  if (group === null) node = stripGroupTag(node);
  else if (typeof group === 'string') node = { ...node, group };
  const target = Math.max(0, Math.min(nodes.length, Math.round(targetIndex)));
  nodes.splice(target, 0, node);
  // normalizeScreenGroups prunes first, so a group emptied by `group: null`
  // still goes away.
  const nextScreen = normalizeScreenGroups({ ...screen, nodes });
  return {
    ...spec,
    screens: spec.screens.map((s, i) => (i === screenIdx ? nextScreen : s)),
  };
}

// Move a whole group block to an explicit z-index, optionally onto another
// screen. Members come out together (preserving relative order) and reinsert
// as one contiguous block; targetIndex is clamped and interpreted AFTER
// removal (same convention as moveNodeInSpec — it addresses where the block's
// BOTTOM member lands), and the landed screen is normalized
// (normalizeScreenGroups): an index interior to ANOTHER group's block
// effectively snaps to that block's boundary instead of fracturing it — the
// moved block itself is contiguous and survives. Group ids are only unique
// PER SCREEN ('group-1' exists on every screen that ever grouped) —
// `sourceScreenId` pins resolution to that one screen (throwing when it has
// no such group); omitted, the first screen with the id wins. A registry
// entry with zero member nodes is an error (a ghost entry must not silently
// vanish). Cross-screen: the registry entry travels too; a colliding id on
// the target mints a fresh `group-N` there (name kept, members re-tagged),
// and all members shift by one common delta so their bounding box stays
// inside the target frame (origin 0 when it can't fit) — internal layout is
// preserved. The source screen's registry entry is pruned.
export function moveGroupInSpec(
  spec: UISpec,
  groupId: string,
  targetIndex: number,
  targetScreenId?: string,
  sourceScreenId?: string,
): UISpec {
  const screenIdx = spec.screens.findIndex(
    (s) =>
      (sourceScreenId === undefined || s.id === sourceScreenId) &&
      (s.groups ?? []).some((g) => g.id === groupId),
  );
  if (screenIdx === -1) {
    fail([
      sourceScreenId === undefined
        ? `Unknown group id: ${groupId}`
        : `Unknown group id on screen ${sourceScreenId}: ${groupId}`,
    ]);
  }
  const screen = spec.screens[screenIdx];
  const members = screen.nodes.filter((n) => n.group === groupId);
  if (members.length === 0) fail([`Group has no members: ${groupId}`]);
  const rest = screen.nodes.filter((n) => n.group !== groupId);

  if (targetScreenId === undefined || targetScreenId === screen.id) {
    const at = Math.max(0, Math.min(rest.length, Math.round(targetIndex)));
    const nodes = [...rest.slice(0, at), ...members, ...rest.slice(at)];
    return {
      ...spec,
      screens: spec.screens.map((s, i) =>
        i === screenIdx ? normalizeScreenGroups({ ...s, nodes }) : s,
      ),
    };
  }

  const targetIdx = spec.screens.findIndex((s) => s.id === targetScreenId);
  if (targetIdx === -1) fail([`Unknown screen id: ${targetScreenId}`]);
  const targetScreen = spec.screens[targetIdx];
  const entry = (screen.groups ?? []).find((g) => g.id === groupId)!;
  const collides = (targetScreen.groups ?? []).some((g) => g.id === groupId);
  const movedId = collides ? freshGroupId(targetScreen).id : groupId;

  // One common delta clamps the members' bounding box into the target frame
  // without disturbing their layout relative to each other.
  const minX = Math.min(...members.map((n) => n.x));
  const minY = Math.min(...members.map((n) => n.y));
  const boxW = Math.max(...members.map((n) => n.x + n.width)) - minX;
  const boxH = Math.max(...members.map((n) => n.y + n.height)) - minY;
  const dx = Math.max(0, Math.min(minX, targetScreen.frame.w - boxW)) - minX;
  const dy = Math.max(0, Math.min(minY, targetScreen.frame.h - boxH)) - minY;
  const moved = members.map((n) => ({
    ...n,
    group: movedId,
    x: n.x + dx,
    y: n.y + dy,
  }));

  const source = pruneScreenGroups({ ...screen, nodes: rest });
  const at = Math.max(
    0,
    Math.min(targetScreen.nodes.length, Math.round(targetIndex)),
  );
  const nextTarget = normalizeScreenGroups({
    ...targetScreen,
    nodes: [
      ...targetScreen.nodes.slice(0, at),
      ...moved,
      ...targetScreen.nodes.slice(at),
    ],
    groups: [...(targetScreen.groups ?? []), { id: movedId, name: entry.name }],
  });
  return {
    ...spec,
    screens: spec.screens.map((s, i) =>
      i === screenIdx ? source : i === targetIdx ? nextTarget : s,
    ),
  };
}

// ── design library ──────────────────────────────────────────────────────────
// Import-derived designSystem/components live as optional top-level UISpec
// fields. They are editor/agent metadata: rendering, preview, and export
// consult `screens` only. The ops below keep them consistent across the
// surfaces that replace whole specs (browser snapshots, set_ui_mock) and
// provide the one path that turns a template into real screen nodes.

// Carry the design library forward across whole-spec replaces that omit it.
// Agent set_ui_mock calls describe SCREENS — when they don't mention
// designSystem/components, the cache's library survives. Passing the field
// explicitly (even as an empty object/array) replaces it — set_design_library
// relies on that. Returns `next` untouched when there's nothing to carry.
// NOT for browser snapshots — those use adoptSnapshotSpec, where the cache's
// library wins even over an INCLUDED client copy.
export function carryLibraryForward(prev: UISpec, next: UISpec): UISpec {
  const carryDesign =
    next.designSystem === undefined && prev.designSystem !== undefined;
  const carryComponents =
    next.components === undefined && prev.components !== undefined;
  if (!carryDesign && !carryComponents) return next;
  const out: UISpec = { ...next };
  if (carryDesign) out.designSystem = prev.designSystem;
  if (carryComponents) out.components = prev.components;
  return out;
}

// Merge policy for browser snapshots: screens come from the snapshot (the
// browser is the source of truth for human edits), the design library comes
// from the cache whenever the cache has one. A client's library fields are at
// best an echo of an earlier broadcast and at worst STALE — a tab whose
// debounced snapshot was in flight when an import/set_design_library landed
// would otherwise silently revert the fresh library on its next drag. The
// browser never edits the library, so the cache copy (including an explicit
// cleared {}/[] state) always wins; the snapshot's copy only fills a
// library-less cache (e.g. a localStorage restore after design.json was
// lost).
export function adoptSnapshotSpec(prev: UISpec, snapshot: UISpec): UISpec {
  const designSystem = prev.designSystem ?? snapshot.designSystem;
  const components = prev.components ?? snapshot.components;
  const out: UISpec = { screens: snapshot.screens };
  if (designSystem !== undefined) out.designSystem = designSystem;
  if (components !== undefined) out.components = components;
  return out;
}

// All problems with a component list, collected: duplicate component ids and
// duplicate node ids within any template (instance stamping relies on
// template-local uniqueness). Shared by set_design_library and set_ui_mock's
// explicit-components path so no whole-library write can smuggle in a
// template that instantiation would corrupt a screen with.
export function validateComponentList(components: UIComponent[]): string[] {
  const errors: string[] = [];
  const ids = new Set<string>();
  for (const component of components) {
    if (ids.has(component.id)) {
      errors.push(`Duplicate component id: ${component.id}`);
    }
    ids.add(component.id);
    const seen = new Set<string>();
    for (const node of component.nodes) {
      if (seen.has(node.id)) {
        errors.push(
          `Duplicate node id within component template "${component.id}": ${node.id}`,
        );
      }
      seen.add(node.id);
    }
  }
  return errors;
}

// Replace the component with the same id, or append. Errors (collected):
// duplicate node ids within the template. Template node coords are the
// component's own space — they never collide with screen node ids, so no
// global check. A replacement that omits sourceFile keeps the prior
// component's provenance (same semantics as the screen path's
// applyEmittedScreen).
export function applyComponentToSpec(
  spec: UISpec,
  component: UIComponent,
): UISpec {
  const errors = validateComponentList([component]);
  if (errors.length) fail(errors);
  const components = spec.components ?? [];
  const idx = components.findIndex((c) => c.id === component.id);
  if (idx === -1) {
    return { ...spec, components: [...components, component] };
  }
  const prior = components[idx];
  const carried =
    component.sourceFile === undefined && prior.sourceFile !== undefined
      ? { ...component, sourceFile: prior.sourceFile }
      : component;
  return {
    ...spec,
    components: components.map((c, i) => (i === idx ? carried : c)),
  };
}

// Stamp a component template into a screen: every template node becomes a
// real node with a fresh globally-unique id (`<componentId>-<n>-<templateId>`,
// smallest untaken n) offset by the insert origin, and the batch lands in a
// new editor-level group named after the component. Errors: unknown
// component/screen. The origin is clamped so the template box stays inside
// the frame where possible.
export function instantiateComponentInSpec(
  spec: UISpec,
  componentId: string,
  screenId: string,
  opts?: { x?: number; y?: number },
): { spec: UISpec; nodeIds: string[]; groupId: string } {
  const component = (spec.components ?? []).find((c) => c.id === componentId);
  const screen = spec.screens.find((s) => s.id === screenId);
  const errors: string[] = [];
  if (!component) errors.push(`Unknown component id: ${componentId}`);
  if (!screen) errors.push(`Unknown screen id: ${screenId}`);
  if (errors.length) fail(errors);
  // Defensive: a template with internal node-id dupes (e.g. arrived via a
  // browser snapshot or hand-edited design.json that skipped the validated
  // write paths) would otherwise stamp DUPLICATE node ids into the screen.
  const templateErrors = validateComponentList([component!]);
  if (templateErrors.length) fail(templateErrors);

  const x = Math.max(
    0,
    Math.min(opts?.x ?? 16, screen!.frame.w - component!.frame.w),
  );
  const y = Math.max(
    0,
    Math.min(opts?.y ?? 16, screen!.frame.h - component!.frame.h),
  );

  const existing = collectIds(spec);
  let n = 1;
  const idsFor = (k: number) =>
    component!.nodes.map((node) => `${componentId}-${k}-${node.id}`);
  while (idsFor(n).some((id) => existing.has(id))) n += 1;
  const ids = idsFor(n);

  const fresh = freshGroupId(screen!);
  const groupId = fresh.id;
  const nodes: UINode[] = component!.nodes.map((node, i) => ({
    ...node,
    id: ids[i],
    x: node.x + x,
    y: node.y + y,
    group: groupId,
  }));

  const nextScreen: UIScreen = {
    ...screen!,
    nodes: [...screen!.nodes, ...nodes],
    groups: [...(screen!.groups ?? []), { id: groupId, name: component!.name }],
  };
  return {
    spec: {
      ...spec,
      screens: spec.screens.map((s) => (s.id === screenId ? nextScreen : s)),
    },
    nodeIds: ids,
    groupId,
  };
}

export type DesignLibraryOutline = {
  designSystem?: UIDesignSystem;
  components: Array<{
    id: string;
    name: string;
    description?: string;
    frame: { w: number; h: number };
    nodeCount: number;
    usedBy?: string[];
    sourceFile?: string;
  }>;
};

// Compact, read-only summary of the design library: the full designSystem
// (it's already small) plus component metadata WITHOUT template nodes — the
// cheap first read. Fetch one full template by passing its componentId to
// the caller's detail path (get_design_library componentId param).
export function describeDesignLibrary(spec: UISpec): DesignLibraryOutline {
  return {
    ...(spec.designSystem !== undefined
      ? { designSystem: spec.designSystem }
      : {}),
    components: (spec.components ?? []).map((c) => ({
      id: c.id,
      name: c.name,
      ...(c.description !== undefined ? { description: c.description } : {}),
      frame: c.frame,
      nodeCount: c.nodes.length,
      ...(c.usedBy !== undefined ? { usedBy: c.usedBy } : {}),
      ...(c.sourceFile !== undefined ? { sourceFile: c.sourceFile } : {}),
    })),
  };
}

// Compact, read-only outline of the layer hierarchy: each screen with its
// nodes in z-order (z = array index; higher = on top). `text` is truncated;
// `rect` carries the box. With a `screenId`, scopes to that one screen (empty
// `screens` if it doesn't exist).
export function describeLayers(spec: UISpec, screenId?: string): LayersOutline {
  const source = screenId
    ? spec.screens.filter((s) => s.id === screenId)
    : spec.screens;
  return {
    screens: source.map((screen) => ({
      id: screen.id,
      title: screen.title,
      frame: screen.frame,
      ...(screen.sourceFile !== undefined
        ? { sourceFile: screen.sourceFile }
        : {}),
      ...(screen.groups !== undefined && screen.groups.length > 0
        ? { groups: screen.groups }
        : {}),
      layers: screen.nodes.map((node, z) => ({
        z,
        id: node.id,
        type: node.type,
        ...(node.text !== undefined ? { text: truncate(node.text, 40) } : {}),
        ...(node.group !== undefined ? { group: node.group } : {}),
        rect: {
          x: node.x,
          y: node.y,
          width: node.width,
          height: node.height,
        },
      })),
    })),
  };
}
