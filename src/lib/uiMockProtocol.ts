// Wire types for the UI mock bridge (browser <-> server) and the mock spec
// itself. The spec is what Claude writes via MCP; the bridge is the duplex
// sync seam between the server-side cache and the live React renderer.

// Curated set of node types — what `<UIMockNode />` knows how to render. Each
// maps to a real shadcn primitive (or a layout primitive) so the rendered mock
// looks the way it would in production. Keep this list aligned with what's in
// `src/components/ui/`. New types: extend the union, the renderer switch, and
// the skill doc — Claude should not produce a type the renderer doesn't know.
//
// Lowercase types are primitives (layout, content, and vector shapes);
// Capitalized types are shadcn components. The shape types (rect/ellipse/
// line/arrow/triangle/star) style through two channels: fill = the background
// channel (`bg-*` / style.backgroundColor), stroke = the border channel
// (`border-*` / style.borderWidth) — see uiResolve.
export type UINodeType =
  | 'div'
  | 'text'
  | 'heading'
  | 'rect'
  | 'ellipse'
  | 'line'
  | 'arrow'
  | 'triangle'
  | 'star'
  | 'Button'
  | 'Input'
  | 'Textarea'
  | 'Badge'
  | 'Separator'
  | 'Image'
  | 'Icon';

// Compass direction a line/arrow points toward inside its bounding box
// (`props.end`). Diagonals run corner-to-corner; the axis values center the
// segment on the box's midline. The arrowhead (arrow type) sits at the `end`.
export type LineEnd = 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w' | 'nw';

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
  // Image; iconName (lucide) for Icon; level (1|2|3) for heading; end
  // (LineEnd compass) for line/arrow; points (3–12) for star; etc.
  props?: Record<string, unknown>;
  // Editor-level group membership — the id of a group in the owning screen's
  // `groups` registry. Groups are an organization/selection aid (the layers
  // tree nests them, the canvas selects them as one); they NEVER change
  // rendering or export — the node list stays flat. Managed by the group ops
  // in uiMockOps (which keep members z-contiguous and prune empty groups).
  group?: string;
};

// A named group of nodes within one screen. Registry lives on the screen so
// names survive membership churn; membership lives on the nodes (`group`).
export type UIGroup = {
  id: string;
  name: string;
};

export type UIScreen = {
  id: string;
  title: string;
  // Frame size in px. Standard sizes: desktop 1280x800, tablet 768x1024,
  // mobile 360x720. Frames are rendered at scale-to-fit; the user's drag/
  // resize coordinates are always in this native frame space.
  frame: { w: number; h: number };
  nodes: UINode[];
  // Editor-level groups (see UIGroup). Optional and absent when empty.
  groups?: UIGroup[];
  // Workspace-relative Swift source this screen was imported from — both
  // provenance AND the in-place export target: Export & Run rewrites this
  // file's matching View body (and restamps the field after creating a new
  // file for a screen that lacked one). Screens WITHOUT a sourceFile export
  // to a derived new file (newScreenTypeNames in specToSwiftUI.ts — never
  // stored; screenFileNames is the chip's client-side prediction of it).
  sourceFile?: string;
  // Content fingerprint (sha-256 prefix) of `sourceFile` at import time —
  // stamped by the import engine alongside sourceFile, never by hand. The
  // source-sync watcher compares it against the live file to mark a screen
  // stale ("code changed since import"). Travels with sourceFile: preserved
  // on replace-when-omitted, dropped on duplicate.
  sourceHash?: string;
};

// ── Design library (import-derived) ─────────────────────────────────────

// One extracted design token. `value` is a CSS color string (hex/rgb/oklch)
// destined for the inline-`style` channel — the canvas/codegen className
// channel only accepts tango theme tokens, so imported app palettes flow
// through `style` (see uiResolve). `name` comes from the source when known
// (asset catalog name, `static let` identifier), else a generated slug.
export type UIColorToken = {
  name: string;
  value: string;
  // How often the import scanner saw it — higher = more load-bearing.
  count?: number;
};

export type UITextStyleToken = {
  name: string; // 'largeTitle', 'system-17-semibold', 'Inter-14', …
  size: number;
  weight?: number; // CSS-style 100–900
  family?: string; // custom font family when not the system font
  count?: number;
};

// Extracted design-system primitives for one imported app. Everything is
// optional and additive: this is guidance for humans + agents composing new
// screens/variations, never consulted by rendering, preview, or export.
export type UIDesignSystem = {
  colors?: UIColorToken[];
  typography?: UITextStyleToken[];
  // Common spacing/radius values, most-used first.
  spacing?: number[];
  radii?: number[];
  // lucide icon names in use (mapped from the app's SF Symbols).
  icons?: string[];
  // Free-form reusable style rules ("cards: radius 12, shadow y2 r8", …).
  notes?: string[];
};

// A reusable component template extracted at import: a named group of nodes
// with coords relative to the template's own (0,0) origin. Instantiating a
// component stamps copies of `nodes` (fresh ids, offset coords) into a
// screen — instances are plain nodes afterwards; the template is never
// referenced at render/export time.
export type UIComponent = {
  id: string; // stable, kebab-case: 'task-row'
  name: string; // human label: 'Task Row'
  description?: string;
  // Template bounding box; nodes live in [0,0]–[w,h].
  frame: { w: number; h: number };
  nodes: UINode[];
  // Screen ids that use this component in the imported app (provenance for
  // "where is this used", not a live link).
  usedBy?: string[];
  // Workspace-relative Swift source the component was extracted from.
  sourceFile?: string;
};

export type UISpec = {
  screens: UIScreen[];
  // Import-derived design library. Both optional + additive: absent on specs
  // that never ran an import. Editor/agent metadata only — rendering,
  // preview, and export consult `screens` exclusively.
  designSystem?: UIDesignSystem;
  components?: UIComponent[];
};

// ── Wire protocol ────────────────────────────────────────────────────────

// Server → browser. Full replace
// for set_ui_mock / clear_ui_mock; appendScreen for add_ui_screen so we don't
// re-broadcast the whole spec when only one screen was added.
export type ServerSetMsg = { type: 'set'; spec: UISpec };
export type ServerAppendScreenMsg = { type: 'append_screen'; screen: UIScreen };
// Server → browser. Per-screen source-file sync state, recomputed when the
// watcher sees a linked .swift file change or when screen provenance changes.
// Only screens with a sourceFile appear; absence = unlinked.
export type SourceSyncStatus = 'synced' | 'stale' | 'missing';
export type ServerSourceSyncMsg = {
  type: 'source_sync';
  statuses: Record<string, SourceSyncStatus>;
};
export type UIMockServerMsg =
  | ServerSetMsg
  | ServerAppendScreenMsg
  | ServerSourceSyncMsg;

// Browser → server. Debounced after local edits; server replaces its cache.
// No broadcast — last-writer-wins, single-browser typical.
export type ClientSnapshotMsg = { type: 'snapshot'; spec: UISpec };
// Browser → server. Live pixel size of the UI panel's render area, sent on
// mount and on debounced resize. Surfaced to Claude via the `get_ui_viewport`
// MCP tool so new screens default to "exactly what fits the user's pane"
// instead of a hardcoded 1280×800.
export type ClientViewportMsg = { type: 'viewport'; w: number; h: number };
// Browser → server. Which screen the user is working in (last selected node's
// screen, or last clicked frame). Drives which screen the preview-host app
// shows on the simulator.
export type ClientActiveScreenMsg = { type: 'active_screen'; screenId: string };
export type UIMockClientMsg =
  | ClientSnapshotMsg
  | ClientViewportMsg
  | ClientActiveScreenMsg;

export const EMPTY_SPEC: UISpec = { screens: [] };
