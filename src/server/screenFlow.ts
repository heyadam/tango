// Screen-flow diagram: layered layout + Excalidraw element generation.
//
// Pure helpers used by the `set_screen_flow` MCP tool. No I/O, no broadcasts,
// no Excalidraw imports — output is a permissive `CanvasElement[]` shaped
// like the rest of the wireframe palette in `tango-ui-sketch`'s SKILL.md.
//
// Tested by screenFlow.test.ts.
import type { CanvasElement } from '@/lib/canvasProtocol';

export type ScreenKind = 'swiftui' | 'uikit' | 'storyboard';
export type EdgeKind = 'push' | 'sheet' | 'cover' | 'present' | 'segue' | 'tab';

export type Screen = {
  id: string;
  name: string;
  kind: ScreenKind;
  filePath?: string;
  summary?: string;
  isEntry?: boolean;
};

export type Edge = {
  from: string;
  to: string;
  kind: EdgeKind;
  label?: string;
};

export type Box = { x: number; y: number; w: number; h: number };
export type LayoutOpts = {
  cardWidth?: number;
  cardHeight?: number;
  hGap?: number;
  vGap?: number;
  originX?: number;
  originY?: number;
};

const DEFAULTS = {
  cardWidth: 240,
  cardHeight: 140,
  hGap: 80,
  vGap: 120,
  originX: 200,
  originY: 200,
} as const;

// BFS-rank screens from entries downward. First-visit wins on cycles, so the
// rank assignment is deterministic for a given input. Orphans land at rank 0
// so they don't disappear off-canvas.
export function layoutScreenFlow(
  screens: Screen[],
  edges: Edge[],
  opts: LayoutOpts = {},
): Map<string, Box> {
  const cardWidth = opts.cardWidth ?? DEFAULTS.cardWidth;
  const cardHeight = opts.cardHeight ?? DEFAULTS.cardHeight;
  const hGap = opts.hGap ?? DEFAULTS.hGap;
  const vGap = opts.vGap ?? DEFAULTS.vGap;
  const originX = opts.originX ?? DEFAULTS.originX;
  const originY = opts.originY ?? DEFAULTS.originY;

  const ids = new Set(screens.map((s) => s.id));

  // Outgoing adjacency, ignoring edges whose endpoints aren't in the screen
  // set so callers don't have to pre-filter.
  const adj = new Map<string, string[]>();
  for (const e of edges) {
    if (!ids.has(e.from) || !ids.has(e.to)) continue;
    if (e.from === e.to) continue; // skip self-loops; rendered as orphan
    const list = adj.get(e.from) ?? [];
    list.push(e.to);
    adj.set(e.from, list);
  }

  // Seed entries: explicit `isEntry` first; otherwise any source (no incoming);
  // otherwise the alphabetically first node so cycle-only graphs still rank.
  const incoming = new Set<string>();
  for (const e of edges) {
    if (ids.has(e.from) && ids.has(e.to)) incoming.add(e.to);
  }
  let entries = screens.filter((s) => s.isEntry).map((s) => s.id);
  if (entries.length === 0) {
    entries = screens.filter((s) => !incoming.has(s.id)).map((s) => s.id);
  }
  if (entries.length === 0 && screens.length > 0) {
    const first = [...screens].sort((a, b) => a.name.localeCompare(b.name))[0];
    if (first) entries = [first.id];
  }

  const rank = new Map<string, number>();
  for (const id of entries) rank.set(id, 0);
  const queue: string[] = [...entries];
  while (queue.length > 0) {
    const cur = queue.shift()!;
    const curRank = rank.get(cur)!;
    for (const next of adj.get(cur) ?? []) {
      if (rank.has(next)) continue;
      rank.set(next, curRank + 1);
      queue.push(next);
    }
  }
  for (const s of screens) {
    if (!rank.has(s.id)) rank.set(s.id, 0);
  }

  const byRank = new Map<number, Screen[]>();
  for (const s of screens) {
    const r = rank.get(s.id)!;
    const list = byRank.get(r) ?? [];
    list.push(s);
    byRank.set(r, list);
  }
  for (const [, list] of byRank) {
    list.sort((a, b) => a.name.localeCompare(b.name));
  }

  const layout = new Map<string, Box>();
  for (const [r, list] of byRank) {
    list.forEach((s, col) => {
      layout.set(s.id, {
        x: originX + col * (cardWidth + hGap),
        y: originY + r * (cardHeight + vGap),
        w: cardWidth,
        h: cardHeight,
      });
    });
  }
  return layout;
}

const EDGE_COLORS: Record<EdgeKind, string> = {
  push: '#1e1e1e',
  sheet: '#2563eb',
  cover: '#7c3aed',
  present: '#db2777',
  segue: '#475569',
  tab: '#0d9488',
};

// Excalidraw element ids accept any string, but we want predictable ones for
// tests + for the user's `Cmd+F` debug experience. Sanitize on the way in.
// Exported so `validateScreenFlowInput` can detect collisions before render
// rather than letting Excalidraw silently overwrite a duplicate-id element.
export function safeId(id: string): string {
  return id.replace(/[^a-zA-Z0-9_-]/g, '_');
}

// We deliberately omit `version` / `versionNonce` / `seed` / `updated` / etc.
// from the emitted elements — the browser-side `DesignerCanvas` runs every
// incoming patch through Excalidraw's `restoreElements`, which fills the
// defaults. This matches the wireframe palette in the `tango-ui-sketch`
// SKILL.md template. If `canvasBridge` ever stops calling `restoreElements`
// or removes that path, every element here would lose its identity fields.

const baseShape = {
  fillStyle: 'solid',
  strokeWidth: 1,
  strokeStyle: 'solid',
  roughness: 0,
  opacity: 100,
  angle: 0,
} as const;

const baseText = {
  ...baseShape,
  fontFamily: 1,
  textAlign: 'left',
  verticalAlign: 'top',
  strokeColor: '#1e1e1e',
  backgroundColor: 'transparent',
} as const;

type BoundArrow = { type: 'arrow'; id: string };

function cardElements(
  screen: Screen,
  box: Box,
  bound: BoundArrow[],
): CanvasElement[] {
  const sid = safeId(screen.id);
  const groupId = `flow-card-${sid}`;
  const cardId = `flow-card-${sid}-rect`;
  const isEntry = !!screen.isEntry;

  const padX = 12;
  const padY = 12;

  // Excalidraw stores bindings bidirectionally: arrows carry start/endBinding
  // and the bound element carries `boundElements: [{type:'arrow', id}]`. Skip
  // the field when there are no bindings — explicit empty arrays are a valid
  // shape but a missing field is what restoreElements expects and matches the
  // existing wireframe palette.
  const boundElements = bound.length > 0 ? bound : undefined;

  const title: CanvasElement = {
    type: 'text',
    id: `flow-card-${sid}-title`,
    x: box.x + padX,
    y: box.y + padY,
    width: box.w - padX * 2,
    height: 24,
    text: screen.name,
    fontSize: 18,
    groupIds: [groupId],
    ...baseText,
  };

  const subtitle: CanvasElement = {
    type: 'text',
    id: `flow-card-${sid}-meta`,
    x: box.x + padX,
    y: box.y + padY + 28,
    width: box.w - padX * 2,
    height: 18,
    text: [screen.kind, screen.filePath].filter(Boolean).join(' · '),
    fontSize: 12,
    groupIds: [groupId],
    ...baseText,
    strokeColor: '#7a7a7a',
  };

  const elements: CanvasElement[] = [
    {
      type: 'rectangle',
      id: cardId,
      x: box.x,
      y: box.y,
      width: box.w,
      height: box.h,
      strokeColor: '#1e1e1e',
      backgroundColor: isEntry ? '#fef3c7' : 'transparent',
      groupIds: [groupId],
      roundness: { type: 3 },
      ...baseShape,
      strokeWidth: isEntry ? 2 : 1,
      ...(boundElements ? { boundElements } : {}),
    },
    title,
    subtitle,
  ];

  if (screen.summary) {
    elements.push({
      type: 'text',
      id: `flow-card-${sid}-summary`,
      x: box.x + padX,
      y: box.y + padY + 52,
      width: box.w - padX * 2,
      // Clamp so a very small `cardHeight` doesn't yield a negative-height
      // text element (Excalidraw won't crash but the box is invalid).
      height: Math.max(20, box.h - padY - 64),
      text: screen.summary,
      fontSize: 12,
      groupIds: [groupId],
      ...baseText,
    });
  }

  return elements;
}

// Pick anchor points on the card edges that match the rough direction of
// travel — Excalidraw's binding will snap to the nearest edge point at render
// time, but a sensible initial `points` keeps the arrow looking right even
// before the user nudges anything.
function arrowEndpoints(src: Box, dst: Box) {
  if (src.y + src.h <= dst.y) {
    // src above dst → bottom-to-top
    return {
      sx: src.x + src.w / 2,
      sy: src.y + src.h,
      ex: dst.x + dst.w / 2,
      ey: dst.y,
    };
  }
  if (dst.y + dst.h <= src.y) {
    // src below dst → top-to-bottom
    return {
      sx: src.x + src.w / 2,
      sy: src.y,
      ex: dst.x + dst.w / 2,
      ey: dst.y + dst.h,
    };
  }
  // same row, side-by-side
  if (src.x < dst.x) {
    return {
      sx: src.x + src.w,
      sy: src.y + src.h / 2,
      ex: dst.x,
      ey: dst.y + dst.h / 2,
    };
  }
  return {
    sx: src.x,
    sy: src.y + src.h / 2,
    ex: dst.x + dst.w,
    ey: dst.y + dst.h / 2,
  };
}

type EdgeBuild = {
  arrow: CanvasElement;
  label?: CanvasElement;
  fromRectId: string;
  toRectId: string;
  arrowId: string;
};

function buildEdge(
  edge: Edge,
  index: number,
  layout: Map<string, Box>,
): EdgeBuild | null {
  if (edge.from === edge.to) return null; // self-loop: skip
  const src = layout.get(edge.from);
  const dst = layout.get(edge.to);
  if (!src || !dst) return null;

  const fromSid = safeId(edge.from);
  const toSid = safeId(edge.to);
  const arrowId = `flow-edge-${fromSid}-${toSid}-${index}`;
  const fromRectId = `flow-card-${fromSid}-rect`;
  const toRectId = `flow-card-${toSid}-rect`;
  const { sx, sy, ex, ey } = arrowEndpoints(src, dst);
  const dx = ex - sx;
  const dy = ey - sy;
  const color = EDGE_COLORS[edge.kind];

  const arrow: CanvasElement = {
    type: 'arrow',
    id: arrowId,
    x: sx,
    y: sy,
    width: dx,
    height: dy,
    points: [
      [0, 0],
      [dx, dy],
    ],
    startBinding: { elementId: fromRectId, focus: 0, gap: 4 },
    endBinding: { elementId: toRectId, focus: 0, gap: 4 },
    endArrowhead: 'arrow',
    strokeColor: color,
    backgroundColor: 'transparent',
    ...baseShape,
  };

  let label: CanvasElement | undefined;
  if (edge.label) {
    // Schema caps `label` at 24 chars, so no slice/ellipsis needed here.
    label = {
      type: 'text',
      id: `${arrowId}-label`,
      x: sx + dx / 2 - 40,
      y: sy + dy / 2 - 8,
      width: 80,
      height: 16,
      text: edge.label,
      fontSize: 11,
      ...baseText,
      strokeColor: color,
      textAlign: 'center',
    };
  }

  return { arrow, label, fromRectId, toRectId, arrowId };
}

export function screenFlowElements(
  screens: Screen[],
  edges: Edge[],
  layout: Map<string, Box>,
): CanvasElement[] {
  // Sort edges canonically before assigning arrow ids so the same parsed
  // graph emits byte-identical Excalidraw element ids across runs — Claude's
  // upstream parser may yield edges in different orders on re-runs of the
  // same project.
  const sortedEdges = [...edges].sort((a, b) => {
    const f = a.from.localeCompare(b.from);
    if (f !== 0) return f;
    const t = a.to.localeCompare(b.to);
    if (t !== 0) return t;
    return a.kind.localeCompare(b.kind);
  });

  const builtEdges: EdgeBuild[] = [];
  sortedEdges.forEach((e, i) => {
    const built = buildEdge(e, i, layout);
    if (built) builtEdges.push(built);
  });

  // Build the rect → arrow back-references so cards carry `boundElements`.
  // Without it Excalidraw's serialize/deserialize cycle drops the bindings.
  const arrowsByRect = new Map<string, BoundArrow[]>();
  for (const b of builtEdges) {
    for (const rectId of [b.fromRectId, b.toRectId]) {
      const list = arrowsByRect.get(rectId) ?? [];
      list.push({ type: 'arrow', id: b.arrowId });
      arrowsByRect.set(rectId, list);
    }
  }

  const out: CanvasElement[] = [];
  for (const s of screens) {
    const box = layout.get(s.id);
    if (!box) continue;
    const rectId = `flow-card-${safeId(s.id)}-rect`;
    // Defensive copy so `cardElements` receives an array reference it owns.
    // Today nothing mutates `arrowsByRect` after this point, but the cost is
    // negligible and it isolates the rect from upstream changes if a future
    // caller reuses the map.
    const bound = [...(arrowsByRect.get(rectId) ?? [])];
    out.push(...cardElements(s, box, bound));
  }
  for (const b of builtEdges) {
    out.push(b.arrow);
    if (b.label) out.push(b.label);
  }
  return out;
}

// Fatal validation: ids unique (raw AND sanitized). Returns a joined error
// message string on failure, null on success — matches the
// `toolErrorResult`-shaped return path in mcp.ts. The sanitized-id check
// catches the `A/B` vs `A.B` collision, where `safeId` collapses both to
// `A_B` and Excalidraw would silently overwrite one card with the other.
//
// Edges that reference unknown screens are NOT fatal — they're surfaced as
// soft diagnostics (`screenFlowDiagnostics().danglingEdges`) and silently
// dropped by `layoutScreenFlow`. This lets the `scan_ios_app` tool emit
// best-effort edge sets without forcing the model to pre-filter against the
// screen list it just received.
export function validateScreenFlowInput(
  screens: Screen[],
  edges: Edge[],
): string | null {
  void edges;
  const errors: string[] = [];
  const seen = new Set<string>();
  const sanitized = new Map<string, string>();
  for (const s of screens) {
    if (seen.has(s.id)) {
      errors.push(`Duplicate screen id: ${s.id}`);
      continue;
    }
    seen.add(s.id);
    const sid = safeId(s.id);
    const prior = sanitized.get(sid);
    if (prior) {
      errors.push(
        `Screen ids ${prior} and ${s.id} collide after sanitization (both → ${sid}); rename one.`,
      );
      continue;
    }
    sanitized.set(sid, s.id);
  }
  if (errors.length === 0) return null;
  if (errors.length === 1) return errors[0];
  return `${errors.length} validation errors:\n - ${errors.join('\n - ')}`;
}

export type ScreenFlowDiagnostics = {
  danglingEdges: Array<{
    from: string;
    to: string;
    reason: 'unknown_from' | 'unknown_to' | 'self_loop';
  }>;
  layoutOverlaps: Array<{ a: string; b: string }>;
};

// Soft diagnostics surfaced in the `set_screen_flow` success payload so the
// model can decide whether to follow up with `screenshot_canvas` or re-call
// with a different `cardWidth`/`cardHeight`. Empty arrays mean "you're done."
export function screenFlowDiagnostics(
  screens: Screen[],
  edges: Edge[],
  layout: Map<string, Box>,
): ScreenFlowDiagnostics {
  const ids = new Set(screens.map((s) => s.id));
  const danglingEdges: ScreenFlowDiagnostics['danglingEdges'] = [];
  for (const e of edges) {
    if (e.from === e.to) {
      danglingEdges.push({ from: e.from, to: e.to, reason: 'self_loop' });
      continue;
    }
    if (!ids.has(e.from)) {
      danglingEdges.push({ from: e.from, to: e.to, reason: 'unknown_from' });
      continue;
    }
    if (!ids.has(e.to)) {
      danglingEdges.push({ from: e.from, to: e.to, reason: 'unknown_to' });
    }
  }

  const boxes: Array<{ id: string; box: Box }> = [];
  for (const [id, box] of layout) boxes.push({ id, box });
  const layoutOverlaps: ScreenFlowDiagnostics['layoutOverlaps'] = [];
  for (let i = 0; i < boxes.length; i++) {
    for (let j = i + 1; j < boxes.length; j++) {
      const a = boxes[i];
      const b = boxes[j];
      if (boxesOverlap(a.box, b.box)) {
        layoutOverlaps.push({ a: a.id, b: b.id });
      }
    }
  }

  return { danglingEdges, layoutOverlaps };
}

function boxesOverlap(a: Box, b: Box): boolean {
  return (
    a.x < b.x + b.w &&
    a.x + a.w > b.x &&
    a.y < b.y + b.h &&
    a.y + a.h > b.y
  );
}
