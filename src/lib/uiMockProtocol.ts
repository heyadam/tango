// Wire types for the UI mock bridge (browser <-> server) and the mock spec
// itself. The spec is what Claude writes via MCP; the bridge is the duplex
// sync seam between the server-side cache and the live React renderer.

// Curated set of node types — what `<UIMockNode />` knows how to render. Each
// maps to a real shadcn primitive (or a layout primitive) so the rendered mock
// looks the way it would in production. Keep this list aligned with what's in
// `src/components/ui/`. New types: extend the union, the renderer switch, and
// the skill doc — Claude should not produce a type the renderer doesn't know.
export type UINodeType =
  | 'div'
  | 'text'
  | 'heading'
  | 'Button'
  | 'Input'
  | 'Textarea'
  | 'Badge'
  | 'Separator'
  | 'Image'
  | 'Icon';

// Every node is absolutely positioned inside its screen frame. Coordinates
// are pixels in the frame's local coordinate space. No nesting in v1 — sibling
// flat list. Group-by-coords lets the human reorganize freely without having
// to maintain a tree.
export type UINode = {
  id: string;
  type: UINodeType;
  x: number;
  y: number;
  width: number;
  height: number;
  // Renderable text for nodes that have a label (text/heading/Button/Badge,
  // and the placeholder of Input/Textarea — see UIMockNode for the mapping).
  text?: string;
  // Tailwind classes applied to the rendered shadcn primitive. Layout-affecting
  // classes (flex/grid/w-*) are ignored — coords win — so use this for visual
  // styling (colors, padding inside the box, typography).
  className?: string;
  // Inline style overrides applied verbatim via React's `style` prop. Use this
  // for colors that aren't theme tokens (raw hex, gradients, custom shadows) —
  // arbitrary-value Tailwind classes like `bg-[#hex]` do NOT work in `className`
  // because the JIT only scans source files at build time, so off-theme color
  // fidelity has to come through here. React inline-style schema (camelCase
  // keys, string or number values). Layout-affecting keys (`position`, `top`,
  // `left`, `right`, `bottom`, `width`, `height`, `inset`, `transform`,
  // `display`, `flex*`, `grid*`) are silently dropped — coords win for layout,
  // same policy as `className`.
  style?: Record<string, string | number>;
  // Component-specific props. shadcn variant/size for Button & Badge; src for
  // Image; iconName (lucide) for Icon; level (1|2|3) for heading; etc.
  props?: Record<string, unknown>;
};

export type UIScreen = {
  id: string;
  title: string;
  // Frame size in px. Standard sizes: desktop 1280x800, tablet 768x1024,
  // mobile 360x720. Frames are rendered at scale-to-fit; the user's drag/
  // resize coordinates are always in this native frame space.
  frame: { w: number; h: number };
  nodes: UINode[];
};

export type UISpec = {
  screens: UIScreen[];
};

// ── Wire protocol ────────────────────────────────────────────────────────

// Server → browser. Mirrors canvasBridge's set/patch dichotomy: full replace
// for set_ui_mock / clear_ui_mock; appendScreen for add_ui_screen so we don't
// re-broadcast the whole spec when only one screen was added.
export type ServerSetMsg = { type: 'set'; spec: UISpec };
export type ServerAppendScreenMsg = { type: 'append_screen'; screen: UIScreen };
export type UIMockServerMsg = ServerSetMsg | ServerAppendScreenMsg;

// Browser → server. Debounced after local edits; server replaces its cache.
// No broadcast — last-writer-wins, single-browser typical.
export type ClientSnapshotMsg = { type: 'snapshot'; spec: UISpec };
// Browser → server. Live pixel size of the UI panel's render area, sent on
// mount and on debounced resize. Surfaced to Claude via the `get_ui_viewport`
// MCP tool so new screens default to "exactly what fits the user's pane"
// instead of a hardcoded 1280×800.
export type ClientViewportMsg = { type: 'viewport'; w: number; h: number };
export type UIMockClientMsg = ClientSnapshotMsg | ClientViewportMsg;

export const EMPTY_SPEC: UISpec = { screens: [] };
