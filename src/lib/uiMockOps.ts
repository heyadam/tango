// Pure, in-place-free mutations for the UI mock spec. This is the single
// source of truth for node-level edits, shared by BOTH surfaces:
//   - server: uiMockBridge wrappers apply an op to the live cache then
//     re-broadcast the whole spec (see uiMockBridge.ts).
//   - browser: UIMockCanvas calls these inside setSpec(prev => op(prev, …)).
// Every function returns a NEW spec (never mutates its input) so React's
// setSpec sees a fresh reference and the server cache stays referentially
// honest. Validation collects ALL problems before throwing, so callers get
// one useful error instead of a fix-one-retry loop.

import type { UINode, UIScreen, UISpec } from './uiMockProtocol';

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
  rect: { x: number; y: number; width: number; height: number };
};

export type ScreenLayers = {
  id: string;
  title: string;
  frame: { w: number; h: number };
  sourceFile?: string;
  layers: LayerInfo[];
};

export type LayersOutline = { screens: ScreenLayers[] };

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
// is NOT copied (a duplicate doesn't mirror the original's source file).
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
  const { sourceFile: _dropped, ...rest } = source!;
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
    screens: spec.screens.map((screen) => ({
      ...screen,
      nodes: screen.nodes.filter((node) => !toDrop.has(node.id)),
    })),
  };
}

// Change a node's z-order within its own screen. `front`/`back` jump to the
// top/bottom of the stack; `forward`/`backward` swap with the adjacent
// sibling. Moves at a boundary are a no-op (still returns a fresh spec).
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
  const nodes = [...screen.nodes];
  const [node] = nodes.splice(idx, 1);
  let target: number;
  switch (op) {
    case 'front':
      target = nodes.length;
      break;
    case 'back':
      target = 0;
      break;
    case 'forward':
      target = Math.min(nodes.length, idx + 1);
      break;
    case 'backward':
      target = Math.max(0, idx - 1);
      break;
  }
  nodes.splice(target, 0, node);
  return {
    ...spec,
    screens: spec.screens.map((s, i) => (i === screenIdx ? { ...s, nodes } : s)),
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
      layers: screen.nodes.map((node, z) => ({
        z,
        id: node.id,
        type: node.type,
        ...(node.text !== undefined ? { text: truncate(node.text, 40) } : {}),
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
