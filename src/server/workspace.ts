import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ensureMemory } from './memory';
import {
  detectXcodeProject,
  ensureTangoDir,
  type IosProjectStatus,
} from './iosBuild';

// The directory the terminal agent operates in: where the in-app terminal
// lands, and where `.mcp.json` and `.claude/tango.md` are managed so the
// `claude` CLI auto-discovers our design tools.
//
// Selection order (see workspaceState):
//   1. process.env.TANGO_WORKSPACE — pinned, picker locked
//   2. ~/.tango/state.json#lastWorkspace — last-picked, if it still exists
//   3. null — picker shown, PTY refuses to spawn until set

export type WorkspaceSource = 'env' | 'persisted' | 'unset';

// Singleton state. Stashed on `globalThis` because Next.js loads route
// handlers in a different module graph from the custom server (server.ts) —
// without this, `currentWorkspace` would always read its module-default
// (`null`) inside route handlers, even after server boot resolution has set
// it. The PTY / canvas WS hubs live in server.ts's graph (since they're
// attached to the WebSocketServer at upgrade), so state mutations from
// route handlers (setWorkspace) propagate via this shared slot.
type WorkspaceSlot = {
  currentWorkspace: string | null;
  workspaceSource: WorkspaceSource;
  iosProject: IosProjectStatus;
  // Workspace path for which detection is currently in flight. The first
  // ensureWorkspace call in a switch sequence sets this; if a second call
  // takes over (user clicks a different workspace mid-detection), the first
  // one's result is dropped at write-back time. Without this guard, a slow
  // detection of an old workspace can clobber a newer one.
  iosDetectionFor: string | null;
};

const SLOT_KEY = '__tangoWorkspaceSlot__';

function getSlot(): WorkspaceSlot {
  const g = globalThis as typeof globalThis & {
    [SLOT_KEY]?: WorkspaceSlot;
  };
  if (!g[SLOT_KEY]) {
    g[SLOT_KEY] = {
      currentWorkspace: null,
      workspaceSource: 'unset',
      iosProject: { kind: 'none' },
      iosDetectionFor: null,
    };
  }
  return g[SLOT_KEY];
}

export class WorkspaceUnsetError extends Error {
  constructor() {
    super('No workspace selected — open the app in a browser to pick one.');
    this.name = 'WorkspaceUnsetError';
  }
}

export function getWorkspace(): string {
  const slot = getSlot();
  if (slot.currentWorkspace == null) throw new WorkspaceUnsetError();
  return slot.currentWorkspace;
}

export function getWorkspaceOrNull(): string | null {
  return getSlot().currentWorkspace;
}

export function getWorkspaceSource(): WorkspaceSource {
  return getSlot().workspaceSource;
}

// Mutates the shared slot. Only callers in this file (boot resolution) and
// workspaceState's setWorkspace should poke this. ensureWorkspace() does NOT
// touch this — it just writes files.
export function _setWorkspaceInternal(p: string | null, source: WorkspaceSource): void {
  const slot = getSlot();
  slot.currentWorkspace = p;
  slot.workspaceSource = source;
}

// Detected Xcode project for the current workspace. Updated by
// ensureWorkspace() after each detection pass. Reset to `{kind: 'none'}` on
// workspace switch (handled inside ensureWorkspace before redetection).
export function getIosProject(): IosProjectStatus {
  return getSlot().iosProject;
}

// Internal mutator — same shape as `_setWorkspaceInternal`. Only ensureWorkspace
// (and tests) should call it; everything else reads via getIosProject().
export function _setIosProjectInternal(status: IosProjectStatus): void {
  getSlot().iosProject = status;
}

// Settings we always want present in the workspace's Claude Code config.
// Merged into whatever's already in settings.json — we don't clobber unrelated
// keys or hooks the user has set.
const REQUIRED_CLAUDE_ENV = {
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
} as const;

// Tango docs body — written to ${workspace}/.claude/tango.md. The user's own
// CLAUDE.md gets a tiny @-import block referencing this file (see
// CLAUDE_MD_SENTINEL_*), so the smallest blast radius for an existing
// project's CLAUDE.md is just our 3-line managed block.
//
// Split into HEAD + (templated iOS section) + TAIL so detection results from
// `detectXcodeProject` can be spliced in. The HEAD covers the design-canvas
// flow; the iOS section (when present) covers the build / install / launch
// loop on the booted simulator; the TAIL is the workspace memory section +
// footer.
const TANGO_MD_HEAD = `# Design canvas (tango)

You're running inside the **tango** workspace. The user is viewing a direct-manipulation design canvas in the left pane of their browser — screens of absolutely-positioned shadcn/Tailwind components they can drag, resize, and text-edit — and this terminal in the right pane. The \`tango-canvas\` MCP server lets you read and modify that canvas:

- \`get_ui_mock\` — read the current design spec (call this first; user tweaks live here)
- \`get_ui_layers\` — read a compact, z-ordered outline of the design (screens → nodes, back-to-front) to grab node ids before editing
- \`get_ui_viewport\` — read the live pixel size of the user's design panel; use it as the default frame size for new screens so the design fills exactly what they see
- \`set_ui_mock\` — replace the whole spec (one or more screens of absolutely-positioned nodes)
- \`add_ui_screen\` — append a screen to an existing flow without touching the others
- \`add_ui_nodes\` — add node(s) to one screen on the LIVE spec (preserves the user's other tweaks; prefer over \`set_ui_mock\` for incremental adds)
- \`update_ui_node\` — patch a single node by id (move/resize/restyle/text) without replacing the whole spec
- \`remove_ui_node\` — delete node(s) by id
- \`remove_ui_screen\` — delete one screen (and its nodes) without touching the others; prefer over \`set_ui_mock\` for discarding variations
- \`reorder_ui_node\` — change a node's z-order within its screen (front/back/forward/backward)
- \`clear_ui_mock\` — empty the spec

For UI design work ("mock my UI", "show me what the X screen would look like", "prototype this flow", "sketch a layout for Y"), follow the **\`tango-ui-mock\`** skill at \`.claude/skills/tango-ui-mock/SKILL.md\` — it transcribes a real production UI (or a described one) into the design surface, where the user can drag, resize, and edit text, and then ship the tweaks back as a reference for the production codebase.

For round-tripping a **SwiftUI** view through the canvas — read a \`.swift\` file and render it on the canvas, let the user tweak it, then regenerate SwiftUI back into the same file — follow the **\`tango-swiftui\`** skill at \`.claude/skills/tango-swiftui/SKILL.md\`. Triggers on any prompt naming a \`.swift\` file, SwiftUI, Xcode, or a Swift View together with read / show / render / mock / sketch / save / write / generate intents. For importing the workspace's existing screens wholesale, follow **\`tango-ui-import\`** at \`.claude/skills/tango-ui-import/SKILL.md\`.

Edits via these tools appear on the user's canvas immediately, and their edits flow back so \`get_ui_mock\` always reflects what's on their screen right now. The spec also persists at \`.tango/design.json\` (survives restarts; \`get_ui_mock\` is still the canonical read).

## The design loop

The fast path from design to running app, end to end:

1. **Import** — you read the workspace's Swift screens and write the design via \`set_ui_mock\` (the \`tango-ui-import\` skill; agent-mediated).
2. **Edit** — the user manipulates the canvas directly; you make incremental edits with the node tools.
3. **Live preview** — the \`preview_start\` tool launches tango's preview-host app on the booted simulator; it renders the design natively and mirrors every canvas edit in under a second, NO rebuild.
4. **Export** — the \`export_run\` tool deterministically generates SwiftUI into \`TangoGenerated/\` inside the detected Xcode project and builds/installs/launches it. No LLM in that path — you only intervene when the user wants generated screens woven into their hand-written code. Generated views render nothing until user code references them: if the result reports \`embedded: false\`, offer to wire \`TangoGeneratedRootView()\` into the app (e.g. in place of the template \`ContentView()\`) — that edit is yours to make, not tango's.

**Ownership rule:** files under \`TangoGenerated/\` are tango-owned — overwritten on every export; never hand-edit them; to change those screens, change the design and re-export. Hand-written screens that have been **imported** become design-owned for their *look*: apply design changes back to those files when the user sends the design to you — don't redesign them ad hoc in Swift.

`;

const TANGO_MD_TAIL = `## Workspace memory

A live memory file lives at \`./tango-memory.md\` — read it now for prior context (recorded design decisions, constraints, todos). When the user states a design decision, constraint, or context worth keeping for future sessions, call the \`remember_note\` MCP tool with the appropriate \`category\` (\`'decision'\`, \`'context'\`, or \`'todo'\`). Don't edit the Summary or Recent sections of \`tango-memory.md\` directly — those are managed by tango. Your own working notes go in the \`Notes (yours)\` block at the bottom, which tango never touches.

---

This file is generated by tango and overwritten on each server boot. Don't hand-edit — put project-specific instructions in your own CLAUDE.md (the part outside the \`tango:start\` … \`tango:end\` block is yours).
`;

function renderIosSection(
  status: IosProjectStatus,
  workspace: string,
): string {
  if (status.kind === 'none' || status.kind === 'error') return '';

  const skillRef =
    'Follow the **`tango-ios-sim`** skill at `.claude/skills/tango-ios-sim/SKILL.md` for the full playbook.';

  if (status.kind === 'detected') {
    const p = status.project;
    const rel =
      path.relative(workspace, p.projectPath) || path.basename(p.projectPath);
    const bundleClause = p.bundleId ? `, bundle id \`${p.bundleId}\`` : '';
    return `## iOS simulator

This workspace is the Xcode ${p.projectKind} at \`${rel}\`, scheme \`${p.scheme}\`${bundleClause}. The booted iOS simulator is iframed into the right sidebar via \`serve-sim\`, so the user is *watching* the simulator while you work.

Build, install, and launch the app on that simulator with the \`tango-canvas\` MCP tools — \`ios_status\` (sanity-check the project + booted devices), \`ios_build_run\` (atomic build → install → launch), \`ios_logs_recent\` (read the running app's recent log output). \`ios_build_run\` is the headline tool. The build is incremental, so it's the closest thing to hot reload without source modifications. You can also *drive* the running app: \`ios_inspect\` (read the on-screen accessibility tree to find a control and its normalized tap coordinates), then \`ios_tap\` / \`ios_gesture\` (swipe) / \`ios_type\` / \`ios_button\` / \`ios_rotate\` — inspect before you tap, you can't see the pixels. ${skillRef}

**Rule:** any time you edit a \`.swift\` file in this workspace, immediately load the \`tango-ios-sim\` skill and call \`ios_build_run\` to reload the simulator. The user is watching it — design changes don't exist for them until the running app reflects them. Don't wait for the user to ask, don't batch edits silently, don't skip the rebuild because "they'll see it next time."

`;
  }

  // ambiguous
  const list = status.candidates
    .map((c) => `\`${path.relative(workspace, c.projectPath) || path.basename(c.projectPath)}\``)
    .join(', ');
  return `## iOS simulator

This workspace contains multiple Xcode projects (${list}) and tango couldn't pick one automatically. Call \`ios_status\` first to see the candidates and their schemes, then pass an explicit \`scheme\` (and \`udid\` if multiple simulators are booted) to \`ios_build_run\`. The booted iOS simulator is iframed into the right sidebar via \`serve-sim\`. Once it's running you can drive it with \`ios_inspect\` → \`ios_tap\` / \`ios_gesture\` / \`ios_type\` / \`ios_button\` / \`ios_rotate\`. ${skillRef}

**Rule:** any time you edit a \`.swift\` file, load the \`tango-ios-sim\` skill and call \`ios_build_run\` (with the resolved \`scheme\`) to reload the simulator. The user is watching it — design changes don't exist for them until the running app reflects them.

`;
}

export function tangoMd(
  iosProject: IosProjectStatus,
  workspace: string,
): string {
  return TANGO_MD_HEAD + renderIosSection(iosProject, workspace) + TANGO_MD_TAIL;
}


// Skill body for `${workspace}/.claude/skills/tango-ui-mock/SKILL.md`.
// Drives terminal-Claude through tango's design canvas: read the production UI
// from the codebase, transcribe it into a shadcn-based mock spec via the
// `set_ui_mock` MCP tool, then read user tweaks back via `get_ui_mock` after
// the user has dragged / resized / edited the mock and pinged Claude.
// Wholly tango-managed, same overwrite policy as `.claude/tango.md`.
const UI_MOCK_SKILL_MD = `---
name: tango-ui-mock
description: Build a high-fidelity shadcn/Tailwind UI design on the tango canvas for the user to drag, resize, and tweak — then read their changes back as a reference for the production codebase. Use whenever the user asks to sketch, wireframe, mock up, prototype, visualize, design, or "see what X would look like" for a UI / screen / page / flow.
---

# UI mock (shadcn / Tailwind)

You're inside a tango workspace. The left pane is a fixed-frame design canvas where shadcn-styled components sit at absolute pixel coordinates. The user can drag, resize, multi-select, and double-click-to-edit-text. Your job is two-way:

1. **Down**: turn a production UI (existing in the codebase, or described by the user) into a mock spec that visualizes it.
2. **Up**: when the user has tweaked the mock and pinged you (typically by clicking "Send to Claude" — you'll see a markdown handoff in the terminal), read the current spec via \`get_ui_mock\` and translate the deltas into responsive Tailwind / shadcn changes in the production source.

For **SwiftUI** workspaces there are two no-LLM shortcuts you should know about (and mention to the user when relevant): \`preview_start\` launches a native live preview of the design on the booted simulator (sub-second updates, no rebuild), and \`export_run\` deterministically generates SwiftUI from the design into \`TangoGenerated/\` and builds/launches it. Files under \`TangoGenerated/\` are tango-owned — regenerated on every export, never hand-edit them. If \`export_run\` reports \`embedded: false\`, no user Swift shows the generated views yet — offer to embed \`TangoGeneratedRootView()\` in the app's entry point.

The canvas renders real shadcn primitives — Button, Input, Badge, Separator, Textarea — plus layout primitives (\`div\`, \`text\`, \`heading\`, \`Image\`, \`Icon\`). For a deliberately low-fidelity wireframe look, use muted \`div\` boxes and placeholder \`text\` nodes instead of fully-styled components.

## Tools

\`get_ui_mock\`, \`get_ui_layers\`, \`get_ui_viewport\`, \`set_ui_mock\`, \`add_ui_screen\`, \`add_ui_nodes\`, \`update_ui_node\`, \`remove_ui_node\`, \`remove_ui_screen\`, \`reorder_ui_node\`, \`clear_ui_mock\` (from the \`tango-canvas\` MCP server, same as the canvas tools). The spec shape:

\`\`\`ts
type UISpec = { screens: UIScreen[] };
type UIScreen = {
  id: string;          // stable, human-readable: 'login', 'dashboard'
  title: string;       // shown above the frame in the panel
  frame: { w: number; h: number };  // pixels
  nodes: UINode[];
  sourceFile?: string; // import provenance — see below
};
type UINode = {
  id: string;          // stable
  type: 'div' | 'text' | 'heading' | 'Button' | 'Input' | 'Textarea'
       | 'Badge' | 'Separator' | 'Image' | 'Icon';
  x: number; y: number;
  width: number; height: number;
  text?: string;
  className?: string;  // Tailwind for visuals only — coords win for layout
  style?: Record<string, string | number>;  // Inline-style overrides — see §5
  props?: {
    // Button:    variant: 'default'|'secondary'|'outline'|'ghost'|'destructive'|'link'
    // Badge:     variant: 'default'|'secondary'|'destructive'|'outline'
    // Input/Textarea: placeholder: string
    // Image:     src: string  (data URLs ok; otherwise a placeholder is shown)
    // Icon:      iconName: string  (a lucide-react export name, PascalCase)
    // heading:   level: 1 | 2 | 3
  };
};
\`\`\`

\`sourceFile\` is import provenance: the workspace-relative Swift file the screen was imported from. Set it only when the screen mirrors a real file, and preserve it when re-emitting an existing screen. Export filenames are always derived from the screen id at export time — never stored, so don't try to record them here.

## Screen variations

When asked for variations of a screen, append each one as its own screen with one \`add_ui_screen\` call per variation — never \`set_ui_mock\` or \`clear_ui_mock\` (they clobber the user's other screens). Give every variation a fresh, globally-unique screen id (\`'<screenId>-v1'\` style) and prefix its node ids with the new screen id so node ids stay unique across the whole mock. Copy the source screen's frame exactly, title it \`'<Title> · vN'\`, and do not copy \`sourceFile\` — a variation is not an import of that file.

## Playbook (down: codebase → mock)

### 1. Find the UI in the codebase

\`Read\` the entry-point page (\`src/app/<route>/page.tsx\`, \`pages/<route>.tsx\`, \`App.tsx\`) and one level of components it composes. Stop as soon as you can list:

- the layout regions (header / nav / main / sidebar / footer)
- the controls inside each region (buttons, inputs, lists, cards, tabs, copy)

If the user described the UI in words instead of pointing at the codebase, write the regions + controls down in a sentence each before drawing.

### 2. Pick a frame

| Form factor                 | Frame size                                                                 |
|-----------------------------|-----------------------------------------------------------------------------|
| **Default (current view)**  | Call \`get_ui_viewport\` and use the returned \`{w, h}\`. Falls back to 1280×800 if it returns nulls (no browser connected). |
| Explicit mobile             | 360 × 720                                                                  |
| Explicit tablet             | 768 × 1024                                                                 |

For "mock my X" / "show me the X screen" / "build a UI for Y" with no form factor specified, **always start with \`get_ui_viewport\`** so the frame matches what the user is actually looking at — a 1280×800 default into a 900-wide pane just produces a horizontal scrollbar and noise.

Multi-screen flows: separate \`UIScreen\` objects, one per screen. The panel tiles them left-to-right with an 80px gutter — your coords stay screen-local. The viewport size is for **single-screen** mocks; for a flow of N screens, scale frames down so the row roughly fits the viewport (e.g. for 3 screens: each frame ≈ \`(viewport.w − 160) / 3\` wide), or accept that the user will pan horizontally to see them all.

### 3. Lay out regions, then controls

**Pass A — regions.** Give each region a \`div\` node with a small \`className\` for visual hint (e.g. \`bg-card\`, \`border-b\`). Coords mark off header / nav / main / sidebar / footer. 16–24px padding from frame edge; 12–16px gutters between regions.

**Pass B — controls.** Inside each region, place the actual controls. Use the right \`type\` per shadcn:

| Control               | \`type\`     | Notes |
|-----------------------|------------|-------|
| Primary / secondary action | \`Button\`  | \`props.variant\` for style; \`text\` is the label |
| Text input            | \`Input\`    | \`props.placeholder\`; height 36–40 |
| Multi-line input      | \`Textarea\` | \`props.placeholder\` |
| Status / tag          | \`Badge\`    | \`props.variant\` |
| Divider               | \`Separator\` | thin (1–2px) horizontal or vertical |
| Avatar / hero image   | \`Image\`    | \`props.src\` if available, otherwise a placeholder shape |
| Glyph                 | \`Icon\`     | \`props.iconName\` (e.g. \`'Search'\`, \`'Settings2'\`) |
| Body copy / list row  | \`text\`     | use \`className\` for size/color |
| Section title         | \`heading\`  | \`props.level\`: 1 (page), 2 (section), 3 (subsection) |
| Card / panel surface  | \`div\`      | \`className\` for \`bg-card border rounded-lg shadow-sm\` etc. |

### 4. Default sizes (good starting points)

- **Button**: 96–160 × 36 (default), 80 × 32 (sm), 120 × 40 (lg)
- **Input / Textarea**: full region width − 32px gutter; Input 36–40, Textarea 80–160 tall
- **Badge**: 56–80 × 22
- **Separator**: full region width × 1
- **Avatar**: 32×32 to 48×48
- **Card**: large enough for its contents + 16–24px inner padding (you set this with the card's children's coords)
- **Icon**: 16×16 (inline) to 24×24 (button), match the surrounding type size

### 5. Style with \`className\` + \`style\`, not coordinates

Visual styling lives on two channels. Pick the right one based on whether the color is a tango theme token or comes from somewhere else (the source UI's brand palette, a referenced design, an explicit hex the user gave you).

**\`className\` — for theme tokens and typography.** Tailwind classes that resolve to the app's palette: \`bg-card\`, \`text-muted-foreground\`, \`border-border\`, \`text-foreground/80\`. Also size, weight, leading, padding, border-radius, shadow utilities, etc. **Layout-affecting Tailwind classes are dropped** by the renderer — coords win — so don't use \`flex\`, \`grid\`, \`w-full\`, \`h-full\`. Examples that work:

- Card surface: \`bg-card text-card-foreground border rounded-lg shadow-sm\`
- Muted body text: \`text-muted-foreground\`
- Heading prominence: handled by \`type: 'heading'\` + \`props.level\`
- Subtle dividing line inside a region: \`bg-border\` on a thin \`div\`

**\`style\` — for off-theme colors and arbitrary CSS.** A React inline-style object (camelCase keys, string or number values) applied verbatim. Use this and only this for any color outside the app's theme palette: exact hex from the source UI, brand gradients, custom shadows, off-theme borders. Inline style wins over both \`className\` and shadcn variants, so it's the right place for "this button is exactly \`#0E7C66\`" or "this hero has Stripe's purple gradient."

**Why not \`className: 'bg-[#0E7C66]'\`?** Tailwind v4's JIT scans source files at build time. Class names that arrive in runtime JSON are never seen by the compiler, so arbitrary-value classes silently render with no CSS rule. \`style\` is the only reliable channel for off-theme color fidelity.

Examples that work:

- A brand-colored button: \`type: 'Button'\`, \`props: { variant: 'default' }\`, \`style: { backgroundColor: '#0E7C66', color: '#ffffff' }\` — the inline style overrides the \`--primary\` paint that \`variant: 'default'\` would have given.
- A hero gradient: \`type: 'div'\`, \`style: { background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)' }\`.
- A custom shadow + border: \`style: { boxShadow: '0 8px 32px rgba(99, 91, 255, 0.24)', borderColor: '#635BFF' }\`.

Anti-patterns:

- Don't put theme tokens in \`style\` — \`style: { color: 'var(--foreground)' }\` is wrong; use \`className: 'text-foreground'\` so a future palette swap re-skins the mock.
- Don't put colors in \`className\` as arbitrary Tailwind values — \`className: 'bg-[#0E7C66]'\` does NOT render a color (see above). Move it to \`style\`.
- Layout-affecting CSS keys (\`position\`, \`top\`, \`left\`, \`width\`, \`height\`, \`transform\`, \`display\`, \`flex*\`, \`grid*\`) are dropped from \`style\` for the same reason layout Tailwind is dropped from \`className\` — coords win.

### 6. Don't trample existing work

Always \`get_ui_mock\` first.

- Empty? \`set_ui_mock\` with your full draft.
- Has screens you want to keep? Use \`add_ui_screen\` to append.
- The user explicitly asked to start over? \`clear_ui_mock\` then \`set_ui_mock\`. Confirm in chat first if it's not obvious from the prompt.

**Incremental edits & layers.** Once a mock exists, prefer the node-level tools over re-sending the whole spec — they operate on the LIVE cache, so the user's drag/resize/text tweaks to every other node survive (\`set_ui_mock\` would clobber them):

- \`get_ui_layers\` — compact z-ordered outline (screens → nodes back-to-front, each with \`z\`, \`id\`, \`type\`, \`text\`, \`rect\`). Cheap way to grab the right node id and see stacking; use \`get_ui_mock\` when you need full styling/props.
- \`add_ui_nodes({ screenId, nodes })\` — drop new node(s) onto a screen; they land on top of the z-order. Ids must be unique across the whole mock.
- \`update_ui_node({ nodeId, patch })\` — change one node's fields (any except \`id\`).
- \`remove_ui_node({ nodeIds })\` — delete node(s); all-or-nothing on unknown ids.
- \`remove_ui_screen({ screenId })\` — delete a whole screen; the safe rejection path for unwanted variations.
- \`reorder_ui_node({ nodeId, op })\` — \`front\`/\`back\`/\`forward\`/\`backward\` within the node's screen (later in the array = rendered on top).

The user has the same controls in the panel (an Add palette and a Layers panel), so your edits and theirs converge on one spec.

### 7. Verify

After writing, **call \`get_ui_mock\` and re-read the spec you just sent** — Claude can't see the rendered pixels, but the spec round-trip catches:

- Nodes overlapping or running off the frame (x+width > frame.w, etc.)
- Empty \`text\` on Buttons / Badges
- Unknown \`type\` strings (validation will have rejected the call — fix and resend)
- Frame dimensions wrong for the form factor

Fix and \`set_ui_mock\` again. Don't tell the user "done" until the spec lines up.

### 8. Tell the user how to tweak

Once the mock is up, surface the affordances in your reply: the user can drag / resize / shift-click multi-select / double-click to edit text / Backspace to delete. They'll click "Send to Claude" when they want you to apply the tweaks back to the production source.

## Playbook (up: mock → codebase)

When you receive a "Send to Claude" handoff (it'll arrive as a markdown message in the terminal, with the spec embedded), or when the user says "apply the mock to the code":

1. \`get_ui_mock\` — always re-read; the embedded JSON in the handoff may be a snapshot from the moment of send, but the live spec is canonical and may have drifted.
2. Diff the current spec against what you originally wrote (if you remember it; otherwise treat it all as authoritative).
3. Find the production source files for the screen(s) — same approach as in step 1 of the down playbook.
4. **Translate to responsive Tailwind**, *not* absolute positioning. The mock's coords are visualization, not the implementation. A \`Button\` at \`(132, 644, 296, 44)\` in a 360-wide frame becomes \`<Button class="w-full">\` inside its container, not \`<Button style={{ position:'absolute', left: 132, top: 644 }}>\`.
5. Map node types straight to imports from \`@/components/ui/\` — \`Button\`, \`Input\`, etc. Use \`<div>\` / \`<h1-h3>\` / \`<p>\` / \`<img>\` for layout/text/image primitives.
6. Preserve behavior: don't delete handlers or routes the existing component had. The mock is about look, not behavior.
7. Tell the user which files you changed and the gist of each change before you finish.

### 9. Record it

After a successful mock or apply pass, \`remember_note({ category: 'context', text: 'UI mock: <one-line shape, e.g. "Settings page mocked, pushed to src/app/settings/page.tsx">' })\`.

## Anti-patterns

- Don't ship absolute-positioned JSX to production. Translate coords → flex/grid.
- Don't use layout-affecting Tailwind on mock nodes (\`flex\`, \`grid\`, \`w-full\`). Coords win, those classes get ignored.
- Don't default to 1280×800 for the desktop case. The user's actual UI panel is rarely that — it's whatever's left after the splitter, agent sidebar, and window chrome. Use \`get_ui_viewport\`.
- Don't \`clear_ui_mock\` without asking.
- Don't invent a \`type\` outside the union. The validator will reject; the user sees an error.
- Don't skip the verify round-trip on \`get_ui_mock\`. Spec JSON looks fine on paper and overflows the frame in practice.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Skill body for `${workspace}/.claude/skills/tango-swiftui/SKILL.md`.
// Round-trips a SwiftUI View through tango's design canvas: read a `.swift`
// file and render it as a spec of shadcn nodes; the user drags / resizes /
// edits; then regenerate SwiftUI back into the same file. All driven from
// terminal-Claude — no new tango UI surfaces. Wholly tango-managed, same
// overwrite policy as `.claude/tango.md`. Description is broad on triggers
// (any prompt naming `.swift` / SwiftUI / Xcode + read/show/save/write/
// render/mock intents) so it auto-invokes reliably.
const SWIFTUI_SKILL_MD = `---
name: tango-swiftui
description: Round-trip a SwiftUI View through tango's design canvas — when a \`.swift\` file or SwiftUI source is involved. Use whenever the user mentions SwiftUI, Swift View, \`.swift\`, or Xcode together with intents to read, show, render, mock, sketch, visualize, save, write, generate, or update the design. Use \`tango-ui-mock\` instead when the UI is generic web/React, not SwiftUI.
---

# SwiftUI ↔ tango canvas

You're inside a tango workspace. The user has a SwiftUI view (in a \`.swift\` file) that they want to see, edit visually, and write back. Two flows:

1. **Read**: turn a \`.swift\` source file into screens on the tango design canvas (high-fidelity shadcn primitives).
2. **Write**: turn the current canvas back into SwiftUI source and update the file the user has selected.

Both flows live in this terminal-Claude session. The user does not see SwiftUI buttons in tango's UI — the canvas just reflects whatever you push to it via MCP, and you regenerate the \`.swift\` source when they ping you.

## Tools

You'll combine your filesystem tools with tango's MCP tools:

- **Filesystem (built-in)**: \`Read\` / \`Write\` / \`Edit\` / \`Glob\` for \`.swift\` files.
- **Design canvas (\`tango-canvas\` MCP)**: \`get_ui_mock\`, \`get_ui_layers\`, \`set_ui_mock\`, \`clear_ui_mock\`, \`get_ui_viewport\`, \`add_ui_screen\`, \`remove_ui_screen\` (delete one screen without touching the others), plus node-level edits on the live spec — \`add_ui_nodes\`, \`update_ui_node\`, \`remove_ui_node\`, \`reorder_ui_node\`. Spec shape is \`{screens: [{id, title, frame:{w,h}, nodes: UINode[]}]}\` — see \`.claude/skills/tango-ui-mock/SKILL.md\` for the full schema, type union, and per-type \`props\`. Imported screens carry an optional \`sourceFile\` (workspace-relative provenance); export filenames are always derived (\`Tango<Pascal(id)>Screen.swift\`, order-dependent dedupe), never stored.

For SwiftUI that uses heavy custom drawing (\`Path\`, \`Canvas\`, complex \`GeometryReader\` math) the node types can't represent, render the closest structural approximation (a \`div\` placeholder with a label) and tell the user what was approximated.

## Read flow (\`.swift\` → tango)

### 1. Identify the source file

In priority order: the path the user named in this turn → the \`.swift\` file you most recently \`Read\` in this conversation → ask the user. Don't guess.

### 2. Read & parse

\`Read\` the file. Identify the top-level \`struct ... : View\` and its \`var body: some View { … }\`. You're translating **only** what the body returns — keep imports, helper types, \`@State\`/\`@Binding\`/\`@Environment\`, computed properties, and \`#Preview\` blocks separate (you'll need them on the writeback).

Walk the body recursively. **Container views** (\`VStack\`, \`HStack\`, \`ZStack\`, \`Group\`, \`ScrollView\`, \`Form\`, \`Section\`, \`NavigationStack\`, \`NavigationView\`) don't render as their own UINodes — they only contribute layout positions to their leaf children. **Modifiers** (\`.padding(...)\`, \`.foregroundColor(...)\`, \`.font(...)\`, \`.background(...)\`, \`.frame(...)\`) attach to whatever leaf they wrap.

### 3. Project to coords

Every leaf becomes one \`UINode\` with absolute pixel coords inside a frame. Infer coords from the container axis:

- \`VStack(spacing: s)\` → children stacked vertically; each child's \`y = previous.y + previous.height + s\`, \`x\` aligned to the container.
- \`HStack(spacing: s)\` → children stacked horizontally; \`x = previous.x + previous.width + s\`, \`y\` aligned to the container.
- \`ZStack(alignment:)\` → children overlap at the same \`(x, y)\`, offset by alignment.
- \`.frame(width:height:)\` modifier → use those pixel values for the node's \`width\`/\`height\`.
- Bare leaves with no \`.frame\` → use a sensible default per type (Button 160×40, Text/heading sized to fit text, TextField full-region width × 40, Image 96×96, Icon 24×24, Separator full-region × 1).
- \`Spacer()\` → leave a gap in the next sibling's coord; don't emit a node.
- \`.padding(p)\` → inflate child coords by \`p\` on the relevant axes.

### 4. Pick a frame

**Default to iPhone proportions** — SwiftUI views are iOS-first, and the user's UI panel is wider-than-tall, so using the raw viewport produces a 16:9 frame that doesn't match how the view will actually render on device.

- **Default**: \`390×844\` (iPhone 15 logical size). If the panel is taller (call \`get_ui_viewport\` to check), scale proportionally — keep the ~9:19.5 ratio, e.g. \`{ w: viewport.w, h: Math.round(viewport.w * 844 / 390) }\` capped at the viewport height.
- **iPad**: \`820×1180\` (iPad Air) if the source uses iPad-only modifiers (\`.navigationSplitViewStyle\`, \`NavigationSplitView\`, \`.regular\` size class checks) or the user mentions iPad.
- **Mac**: only fall back to the raw \`get_ui_viewport\` size when the source is clearly a macOS app (\`WindowGroup\` with macOS modifiers, \`.frame(minWidth: 800, minHeight: 600)\` style desktop sizing) or the user explicitly says "Mac".

### 5. Push it

\`set_ui_mock({ spec: { screens: [{ id, title, frame, nodes }] } })\`. Use the file's stem as both \`id\` and \`title\` (e.g. \`OnboardingView\`). One screen per top-level View; if the file declares multiple Views, emit a screen per View. Set each screen's \`sourceFile\` to the workspace-relative path of the .swift file it was translated from (omit it for screens that don't mirror a single real file, and for TangoGenerated re-imports). \`get_ui_mock\` first to avoid trampling existing screens — use \`add_ui_screen\` to append alongside them.

### 6. Verify

Immediately re-read the spec via \`get_ui_mock\` and check:

- Nodes overflow the frame (\`x + width > frame.w\`, etc.)
- Buttons / Badges with empty \`text\`
- Unknown \`type\` strings (validation will have rejected — fix and resend)
- Mismatched container axes (everything stacked the wrong way)

Fix and re-push. Don't tell the user "rendered" until the spec round-trips clean.

## Write flow (tango → \`.swift\`)

### 1. Identify the target file

In priority order: the path the user named in this turn → the \`.swift\` file you most recently \`Read\` in this conversation → ask the user. Don't invent a brand-new path without confirming.

### 2. Read the canvas

\`get_ui_mock\`. The spec is canonical — the user has likely dragged / resized / edited text since you last set it.

### 3. Infer SwiftUI containers from positions

Canvas siblings are absolutely positioned — you have to recover the SwiftUI layout. Cluster them:

- Siblings with similar \`y\` and rising \`x\` → wrap in \`HStack(spacing:)\`. \`spacing\` ≈ mean gap between adjacent nodes.
- Siblings with similar \`x\` and rising \`y\` → wrap in \`VStack(spacing:)\`.
- Siblings overlapping in both axes → wrap in \`ZStack\`.
- A leaf with non-trivial offset from its container origin → use \`.padding(...)\` rather than a wrapping container.
- Two clusters at the same y-band but very different heights → the shorter one usually belongs in a \`.frame(alignment:)\` of the taller one rather than its own column.
- A node spanning ≈ the full container width with siblings stacked above and below → wrap the row in an \`HStack\` containing the leaf and \`Spacer()\`s on either side, sitting inside the outer \`VStack\`.

### 4. Map nodes → SwiftUI

Use the cheat sheet below — the **UINode → SwiftUI** mapping is the inverse of the **SwiftUI → UINode** table in this skill, with container inference layered on top per §3. Translate \`className\` (theme tokens) to the SwiftUI equivalent: \`text-foreground\` → \`.foregroundColor(.primary)\`, \`text-muted-foreground\` → \`.foregroundColor(.secondary)\`, \`bg-card\` → \`.background(Color(.secondarySystemBackground))\`, \`bg-muted\` → \`.background(Color(.tertiarySystemBackground))\`, \`bg-accent\` → \`.background(.tint)\`, \`border-border\` → \`.overlay(RoundedRectangle(...).stroke(Color(.separator)))\`. Translate \`style\` (off-theme inline CSS) verbatim: \`{ color: '#0E7C66' }\` → \`.foregroundColor(Color(hex: "0E7C66"))\`, \`{ background: 'linear-gradient(...)' }\` → \`.background(LinearGradient(...))\`, etc.

### 5. Stitch & write

Replace **only the \`body\`** of the original View. Preserve everything else byte-for-byte: imports, helper types, state, computed properties, comments above the body, \`#Preview\` blocks.

Show the proposed diff in chat **before** you \`Edit\`/\`Write\`. If the user said "save" / "save back" / "update", that's confirmation. If they just asked you to "write the design", show the diff and wait.

### 6. Don't break the build

Don't run \`xcodebuild\` — out of scope for this skill. But do sanity-check your output for the SwiftUI compile pitfalls that bite most often:

- **Multi-statement \`body\` without \`@ViewBuilder\`.** If the body has more than one expression at the top level, wrap them in a container (\`VStack\`, \`Group\`) — \`some View\` requires a single returned view.
- **\`Color(hex:)\` is not built into SwiftUI.** If you use it, also emit a small \`fileprivate extension Color { init(hex: String) { … } }\` at the bottom of the file (or use \`Color(red:green:blue:)\` directly).
- **Modifier order matters.** \`.padding().background()\` paints the background outside the padding; \`.background().padding()\` paints it inside. Match the visual you saw in the mock.
- **Ambiguous \`Color\` literal.** \`.foregroundColor(.red)\` is a SwiftUI Color; \`.foregroundColor(Color.red)\` is the same; raw \`Color("brand")\` looks up an asset that may not exist — only use that form if the user clearly has the asset.
- **\`.frame()\` with no width AND no height** is a no-op. Always pass at least one dimension when constraining a view.
- **\`Image(systemName:)\` requires iOS 13+ / macOS 11+.** If the file targets earlier, fall back to \`Image("…")\` with an asset.
- **\`@State\` outside a \`View\` body.** Property wrappers belong on stored properties of the View struct, not inside computed properties or functions.

## Mapping cheat sheets

### SwiftUI → UINode

| SwiftUI                                                | UINode \`type\`              | Notes                                                                 |
|--------------------------------------------------------|----------------------------|-----------------------------------------------------------------------|
| \`Text("…")\`                                            | \`text\`                     | Promote to \`heading\` + \`props.level\` (1/2/3) when font is \`.largeTitle\`/\`.title\`/\`.title2\`. |
| \`Button("…") { }\`                                      | \`Button\`                   | \`props.variant\`: \`default\` (\`.borderedProminent\` / no style), \`secondary\` (\`.bordered\`), \`outline\` (\`.bordered\` + \`.tint(.gray)\`), \`ghost\` (\`.plain\`), \`destructive\` (\`.destructive\` role), \`link\` (\`.borderless\`). \`text\` = label. |
| \`TextField("…", text:)\`                                | \`Input\`                    | \`props.placeholder\` = the label string.                               |
| \`SecureField\` / \`TextEditor\`                           | \`Input\` / \`Textarea\`        | \`SecureField\` → \`Input\`; \`TextEditor\` → \`Textarea\`.                    |
| \`Divider()\`                                            | \`Separator\`                | Horizontal in \`VStack\`, vertical in \`HStack\` — pick by container axis. |
| \`Image(systemName: "xyz")\`                             | \`Icon\`                     | \`props.iconName\` = best lucide-react match. Common: \`gear\`→\`Settings\`, \`magnifyingglass\`→\`Search\`, \`chevron.right\`→\`ChevronRight\`, \`plus\`→\`Plus\`, \`xmark\`→\`X\`, \`trash\`→\`Trash2\`, \`bell\`→\`Bell\`, \`house\`→\`Home\`, \`person\`→\`User\`. On miss, closest visual match. |
| \`Image("asset")\` / \`AsyncImage(url:)\`                  | \`Image\`                    | \`props.src\` if it's a URL; otherwise omit and the renderer shows a placeholder. |
| \`Capsule().background(…)\` with text overlay            | \`Badge\`                    | \`props.variant\` per fill / border style.                              |
| \`Toggle\`, \`Picker\`, \`Slider\`, \`Stepper\`, \`DatePicker\`, \`ColorPicker\`, \`ProgressView\` | \`Button\` (placeholder)   | UI mock can't represent these natively. Use \`text\` = \`"<ViewName>: <label>"\` (e.g. \`Toggle: Notifications\`). On writeback, restore the original SwiftUI from a hint stashed via \`remember_note\`, else leave a \`// TODO: <ViewName>\` and ask the user. |
| \`List\` / \`ForEach\` row                                 | \`div\` per row + child nodes | Flatten the rows. Add a \`Separator\` between them if the SwiftUI used \`.listStyle(.plain)\`. |
| \`VStack\` / \`HStack\` / \`ZStack\` / \`Group\` / \`ScrollView\` / \`Form\` / \`Section\` | (none — container)         | Containers don't emit nodes; their children do, with positions inferred from the container axis. |
| \`Spacer()\`                                             | (none — gap)               | Translate by leaving a gap in the next sibling's coords.               |
| \`.padding(p)\`                                          | (offset)                   | Inflate child coords by \`p\` on the relevant axes.                     |
| \`.frame(width:height:)\`                                | (sets \`width\`/\`height\`)     | If only one dim given, use the default for the other.                  |
| \`.foregroundColor(.theme)\` / \`.foregroundStyle(.primary)\` | \`className\`                | \`text-foreground\` / \`text-muted-foreground\` per role.                  |
| \`.foregroundColor(Color(red:green:blue:))\` / off-theme | \`style.color: '#hex'\`      | Off-theme colors must be inline — Tailwind v4's JIT can't see runtime arbitrary values. |
| \`.background(Color.theme)\`                             | \`className\`                | \`bg-card\` / \`bg-muted\` / \`bg-accent\` per intent.                       |
| \`.background(Color(red:green:blue:))\` / gradients      | \`style.background: ...\`    | Inline, same reasoning.                                                |
| \`.font(.largeTitle/.title/.title2)\`                    | \`type: 'heading'\`, \`props.level: 1/2/3\` | Promote \`text\` → \`heading\`.                              |
| \`.font(.headline/.body/.caption)\`                      | \`className\`                | \`text-lg font-semibold\` / (default) / \`text-xs text-muted-foreground\`. |

### UINode → SwiftUI

Inverse of the above plus container inference (Write flow §3). Layout-affecting CSS keys in \`style\` are dropped by the renderer (\`position\`, \`top\`, \`left\`, \`width\`, \`height\`, \`transform\`, \`display\`, \`flex*\`, \`grid*\`) so you'll never see them on read; on write, infer SwiftUI layout from coords, not from any (absent) CSS hints.

## Round-trip & safety

- **Don't** run \`xcodebuild\`, modify \`.xcodeproj\`, or touch \`Package.swift\`.
- **Don't** delete files. **Don't** create new \`.swift\` files unless the user explicitly asks.
- **Confirm before overwriting.** Show the diff. If the user asked to "save" / "save back" / "update", that's confirmation; if they just asked you to "write the design", show the diff and wait.
- **Preserve non-body code.** Imports, types, state, computed properties, helpers, \`#Preview\` blocks — read them, keep them, write them back unchanged.
- **Round-trip stability.** When reading a file you may have to write back, capture the original SwiftUI fragments that don't have UI mock equivalents (\`Toggle\`, \`Picker\`, custom views) so you can restore them on the way out. Stash them via \`remember_note({ category: 'context', text: '<ViewName>: original Toggle/Picker fragments stashed for writeback: <fragment>' })\`.
- **Mention the file.** Always tell the user which file you're about to read or write before you act.

## Record it

After a successful read or write pass: \`remember_note({ category: 'context', text: '<ViewName>: read/wrote SwiftUI ↔ tango UI mock' })\`.

## Anti-patterns

- Don't try to render heavy custom drawing as fake controls — a labeled \`div\` placeholder plus a note to the user is more honest than a broken-looking \`Button\`.
- Don't ship absolute-positioned SwiftUI back to the file. Use \`VStack\`/\`HStack\`/\`ZStack\` inferred from sibling clustering; coords are visualization, not implementation.
- Don't write to \`.swift\` files outside the workspace without checking with the user — paths the user named are fine; paths you guessed are not.
- Don't put off-theme colors in \`className\` — Tailwind JIT can't see runtime arbitrary values; always use the \`style\` field.
- Don't claim "done" until you've round-tripped the spec via \`get_ui_mock\` (read) or shown the diff (write).

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Skill body for `${workspace}/.claude/skills/tango-ios-sim/SKILL.md`.
// Drives terminal-Claude through the iOS build / install / launch loop on the
// booted iOS Simulator (which the user already has iframed into tango's right
// sidebar via serve-sim). Triggered by build / run / launch / install /
// rebuild / deploy intents in iOS / Xcode / Swift / SwiftUI contexts. Distinct
// from `tango-swiftui` (canvas round-tripping; explicitly NOT a build skill).
const TANGO_IOS_SIM_SKILL_MD = `---
name: tango-ios-sim
description: Build the workspace's Xcode project, install the resulting .app on the booted iOS simulator, launch it, and drive it — the dev loop for iterating on a SwiftUI / UIKit app while the user watches the simulator iframed in tango's right sidebar. Use whenever the user says "build", "run", "launch", "install", "rebuild", "deploy", "compile", "ship", "preview", "try it", "test on the sim", "push to sim", "open in simulator", "iterate", "see the change", "fix the build", or "why isn't it building" in an iOS / Xcode / Swift / SwiftUI context, and especially after the user has accepted a Swift edit you proposed. Also use to *interact with* the running app — "tap the login button", "type my email into the field", "swipe to the next card", "scroll down", "press home", "rotate to landscape", "what's on screen right now" — via the simulator-control tools. Also use for log investigation prompts ("check the logs", "what's the app saying", "any crashes"). Distinct from \`tango-swiftui\` (which round-trips a SwiftUI View through tango's canvas without ever building).
---

# iOS build / install / launch loop

You're inside a tango workspace whose Xcode project tango has already detected (see the "iOS simulator" section in your \`.claude/tango.md\`). The user has the booted iOS simulator iframed into the right sidebar via \`serve-sim\` — they're literally watching the app run while you edit. Your job: take whatever Swift edits land and get the running app on the simulator to reflect them, fast.

## Tools

The \`tango-canvas\` MCP server exposes two groups of tools for this loop.

**Build / run / logs:**

- \`ios_status\` — fast read-only check. Returns \`{ project, bootedDevices, activeDeviceUdid }\`. \`project\` mirrors what's in \`tango.md\`; \`bootedDevices\` lists everything \`xcrun simctl list devices booted\` reports; \`activeDeviceUdid\` is the simulator the iframe is showing (from \`serve-sim\`'s preview API) so your build targets the same device the user is looking at.
- \`ios_build_run\` — the headline tool. Atomic \`xcodebuild\` → \`simctl install\` → \`simctl terminate\` → \`simctl launch\`. Inputs are all optional: \`scheme\`, \`udid\`, \`configuration\` (Debug / Release; default Debug), \`bringForeground\` (default true; terminates the running app before launch so it relaunches with the new binary).
- \`ios_logs_recent\` — calls \`xcrun simctl spawn <udid> log show\` with a predicate scoped to the running app's bundle id and process name. Use after \`ios_build_run\` if the user reports unexpected runtime behavior.

**Drive the running app** (serve-sim under the hood; all coordinates are **normalized 0..1** — \`{0, 0}\` top-left, \`{1, 1}\` bottom-right):

- \`ios_inspect\` — read the on-screen accessibility tree. Returns \`{ screen, elements }\`; each element has \`label\`, \`value\`, \`role\`, \`type\`, \`enabled\`, a pixel \`frame\`, and a \`centerNorm\` {x, y} ready to hand straight to \`ios_tap\`. **This is how you aim** — you cannot see the simulator's pixels, so inspect to locate a control, then tap its \`centerNorm\`.
- \`ios_tap\` — tap once at \`{x, y}\`.
- \`ios_gesture\` — swipe / drag from \`{fromX, fromY}\` to \`{toX, toY}\` (lists, paging, pull-to-refresh).
- \`ios_type\` — type \`text\` into the focused field (US keyboard; does **not** press Return — tap the field first to focus it).
- \`ios_button\` — press a hardware button (\`home\` default; \`lock\` / \`siri\` / \`side\`).
- \`ios_rotate\` — set orientation (\`portrait\` | \`portrait_upside_down\` | \`landscape_left\` | \`landscape_right\`).

All the drive tools take an optional \`udid\`; omit it to target the simulator serve-sim is streaming (the one the user is watching). They return a clear "simulator preview not ready" error if no device is being streamed.

\`tango-canvas\` also exposes the design-canvas tools (\`get_ui_mock\` / \`set_ui_mock\` and friends) — those are for *design*, not *running*. If the user wants to see a SwiftUI file on the canvas, that's \`tango-swiftui\`. If they want to run the app, that's this skill.

## Playbook

### 1. Confirm the project + device (FIRST CALL ONLY)

Call \`ios_status\` **once at the start of a session** — and any time the user says "switch to X" / "use the Y scheme" / "use the iPad simulator." Don't pre-call it before every \`ios_build_run\`: that tool re-resolves the active device internally, so a per-build \`ios_status\` shells out to \`simctl list\` for nothing and adds latency to the rebuild loop.

What to do with the result:

- \`project.kind === 'none'\`: the workspace has no Xcode project. Tell the user; nothing more this skill can do.
- \`project.kind === 'error'\`: surface the error verbatim. The most common cause is \`xcodebuild\` not on PATH (\`xcode-select --install\` fixes it).
- \`project.kind === 'ambiguous'\`: multiple projects. Pick by the user's intent (the one they named, or the one whose scheme matches the file they just edited) and pass it explicitly to \`ios_build_run\`.
- \`project.kind === 'detected'\` and \`bootedDevices.length === 0\`: ask the user to boot a simulator. The Mac UI path is **Spotlight → Simulator.app** (or Xcode → Window → Devices and Simulators). The CLI path is \`xcrun simctl list devices available\` to pick a device, then \`xcrun simctl boot '<Name>'\` to boot it. The "don't \`simctl boot\` a different device" rule from the anti-patterns is for the case where one is *already booted* and the iframe is showing it — when zero are booted, booting any is the right move.
- \`project.kind === 'detected'\` and \`bootedDevices.length >= 1\`: proceed.

### 2. Build, install, launch

Call \`ios_build_run\` with no arguments unless the user gave you a reason to override. Typical:

\`\`\`json
{ "name": "ios_build_run" }
\`\`\`

Override examples:

- User asked for Release: \`{ "configuration": "Release" }\`
- User has multiple booted simulators and named one: \`{ "udid": "<the-udid-from-ios_status>" }\`
- Ambiguous project; user picked a scheme: \`{ "scheme": "MyAppDev" }\`
- User wants the running app left alone (e.g. they're inspecting state): \`{ "bringForeground": false }\`

Result on success: \`{ ok: true, bundleId, pid, appPath, durationMs }\`. Tell the user what happened in one sentence — *"Built and launched in 9.2s; the simulator should be showing the new build."* Don't dump the appPath unless they ask.

Result on failure: \`{ ok: false, stage, message, errors }\`. \`stage\` is one of \`detect\` / \`build\` / \`install\` / \`launch\`. The \`errors\` array contains real \`xcodebuild\` \`error:\` lines, deduplicated string-exact and capped at 20 — but Swift's diagnostics are *cascading*: a single missing identifier produces N near-identical lines that differ only by file:line:col, and the string-exact dedupe doesn't collapse them. **Don't paste 20 near-duplicates back at the user.** Identify the root cause once (e.g. \`cannot find 'foo' in scope\`), summarize it in one sentence, and list the file:line locations where it's reported. For non-build stages (\`install\` / \`launch\`), \`errors\` is usually empty and \`message\` carries the signal — surface that.

### 3. After the launch

When the app shows up on the simulator the user can see it. If they describe a runtime issue ("the button doesn't do anything", "it crashes on tap"), call \`ios_logs_recent\` with default args first — \`xcrun simctl spawn ... log show\` for the last 30 seconds, scoped to the bundle's subsystem and process name. Inspect for \`error\`/\`fault\` level entries and stack-trace snippets. If 30 seconds isn't enough, raise \`sinceSeconds\`.

### Driving the running app (tap / type / swipe / buttons / rotate)

When the user asks you to *interact* with the app — "tap the login button", "fill in the email field", "swipe to the next page", "go to the home screen", "rotate it" — use the drive tools, don't ask the user to do it by hand.

**Rule: \`ios_inspect\` before \`ios_tap\`.** You can't see the simulator's pixels — guessing coordinates misses. The flow is always:

1. Call \`ios_inspect\` to get the on-screen elements. Find the one you want by its \`label\` / \`value\` / \`role\` (e.g. a button labeled "Log in").
2. Pass that element's \`centerNorm\` straight to \`ios_tap({ x, y })\`. Same for the start/end points of an \`ios_gesture\` swipe.
3. To enter text: \`ios_tap\` the field first (so it has focus), then \`ios_type({ text })\`. \`ios_type\` does not press Return — submit by tapping the submit control (inspect → tap) or, where appropriate, an \`ios_button\`.

Re-\`ios_inspect\` after any action that changes the screen (a tap that navigates, a swipe) — the previous coordinates are stale. If \`ios_inspect\` comes back with an \`errors\` array (accessibility momentarily unavailable, app mid-transition), wait a beat and retry once. Coordinates are normalized 0..1; never feed pixel values to \`ios_tap\` / \`ios_gesture\`.

Mention what you did in one short sentence ("Tapped Log in; the email screen is up now"). The user is watching, so don't over-narrate — but do say what you touched in case the tap landed somewhere unexpected.

### 4. The hot-reload story

**Rule:** after **any** Swift edit lands, call \`ios_build_run\` immediately — same turn, no batching. The user is watching the simulator iframed in their right sidebar; the change isn't real to them until the running app reflects it.

There's no native SwiftUI hot reload, so the dev loop is:

1. User asks for a UI/code change.
2. You edit the \`.swift\` file (use \`tango-swiftui\` for UI mock-driven edits if it's a layout change; otherwise \`Read\` + \`Edit\` directly).
3. Call \`ios_build_run\` with no overrides unless the user gave you a reason. xcodebuild is incremental, so the second build is much faster than the first. Realistic ranges on M-series silicon: ~5–15s for a small UI tweak, 20–60s for projects with deep package graphs or first-build SwiftPM resolution, and ~2–5 minutes for a fully cold rebuild. Set the user's expectations accordingly — don't promise "instant."
4. Briefly tell the user the rebuild is in flight and what duration it took.

After several rebuilds in a session, if the loop feels slow and the user asks for true sub-second hot reload, tell them about [Inject](https://github.com/krzysztofzablocki/Inject):

> Inject is a third-party SwiftPM package that hot-swaps SwiftUI views in a running simulator app. It needs a one-time setup: add the \`Inject\` package, add \`@ObservedObject private var iO = Inject.observer\` to each View struct, and wrap their bodies in \`.enableInjection()\`. After that, saving a \`.swift\` file rebuilds *just that view* in seconds, no relaunch.

Don't auto-install Inject — it's source-modifying. Quote the setup if the user opts in, then make the changes they approve.

## Common errors and fixes

- **\`xcodebuild not found — install the Xcode Command Line Tools with \`xcode-select --install\`\`** — vanilla machine; CLT not installed. The fix is in the message; relay it.
- **\`Scheme '<X>' is not currently configured for the build action.\`** — typo, or the scheme isn't shared. Run \`xcodebuild -list\` (or call \`ios_status\`) and pick from the listed schemes.
- **\`Unable to find a destination matching the provided destination specifier\`** — the simulator UDID changed (rebooted, deleted, runtime upgraded), or the project's deployment target is newer than the booted runtime. Re-call \`ios_status\` to get the current UDID; if the runtime mismatch is real, ask the user to install the matching iOS runtime in Xcode → Settings → Platforms.
- **\`The run destination is not valid for Running the scheme\`** — distinct from the above; usually means scheme is iOS-only but the destination spec is malformed (or vice versa). Verify scheme + destination both target iOS Simulator.
- **\`No such module 'X'\`** after a package change — the SwiftPM cache is stale. Delete \`<workspace>/.tango/DerivedData/SourcePackages\` and rebuild. (Tango owns \`.tango/DerivedData/\`; safe to remove.)
- **\`module 'X' was not compiled with library evolution support\`** — common in framework cycles, especially binary XCFrameworks. Either enable \`BUILD_LIBRARY_FOR_DISTRIBUTION=YES\` on the producing target or rebuild the dependency.
- **\`Application could not be installed: ApplicationVerificationFailed\`** — code-signing mismatch with the simulator runtime. Usually fixed by selecting a development team in Xcode → Signing & Capabilities, or by setting \`CODE_SIGN_IDENTITY=""\` for simulator builds.
- **Build hangs / 5-min timeout** — the first build of a fresh project resolves SwiftPM dependencies and can be slow. \`ios_build_run\` has a 5-minute timeout; if it times out, run \`xcodebuild\` once manually in the terminal to warm the cache, then retry.

## Anti-patterns

- **Don't run raw \`xcodebuild\` in the shell** when \`ios_build_run\` covers the same path — you'll skip the install/launch step and the user won't see the change.
- **Don't \`simctl boot\` a different device when one is already booted** — the iframe is bound to whatever was booted via \`serve-sim\`'s detection. Switching under it leaves the iframe looking at nothing. (When *no* device is booted yet, booting any one is fine — see step 1.)
- **Don't pass a hardcoded \`udid\`.** UDIDs are per-machine and change when the user re-creates a simulator. Always source the udid from \`ios_status\` (or omit it and let \`ios_build_run\` resolve it for you).
- **Don't run \`ios_build_run\` while a previous one is still in flight.** xcodebuild's DerivedData lock will serialize them, but the second build looks like a hang as it waits for the first to finish. Wait for the first call to return before initiating another.
- **Don't pass \`bringForeground: false\` for routine rebuilds.** With it false, the new binary installs but the running stale process keeps running — successful builds *look like* nothing changed and the user is confused. Only set it false when the user specifically asked to keep the running app (e.g. they're inspecting state).
- **Don't \`Edit\` \`Info.plist\` to change the bundle id mid-session.** The detected \`bundleId\` is cached at workspace ensure time; \`ios_logs_recent\` will query the wrong subsystem after the change and you'll misdiagnose silence as "no logs."
- **Don't dump the whole \`xcodebuild\` log to the user** — surface the digest from \`errors\`, not the raw stream. Cascading Swift errors look like 20 distinct entries; treat them as one root cause with N locations.
- **Don't guess tap coordinates.** You can't see the pixels — always \`ios_inspect\` first and tap an element's \`centerNorm\`. Hand-picked coordinates miss, and a miss looks to the user like the tool is broken.
- **Don't keep tapping stale coordinates after the screen changed.** A tap that navigates, or a swipe, invalidates the previous \`ios_inspect\` result — re-inspect before the next tap.
- **Don't add Inject without explicit user approval.** It modifies source. Quote the setup, wait for the green light.

## Record it

After the **first** successful build for a workspace, ever, record the cadence: \`remember_note({ category: 'context', text: 'iOS dev loop: scheme <Scheme>, device <Device>; rebuild ~Ns for small edits' })\`. \`Read\` \`tango-memory.md\` first to check for an existing entry — don't add a duplicate on every session start.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;


// Skill body for `${workspace}/.claude/skills/tango-ui-import/SKILL.md`.
// The agent-mediated half of the hybrid translation: importing existing /
// hand-written SwiftUI onto the design canvas. (The other direction — canvas
// → code — is deterministic via the `export_run` tool; no skill needed.)
const UI_IMPORT_SKILL_MD = `---
name: tango-ui-import
description: Import a workspace's existing SwiftUI screens onto the tango design canvas as editable design screens. Use when the user asks to "import my screens", "bring my app into tango", "load my UI onto the canvas", "show all my screens in the editor". (Tango's Import button runs its own built-in fast import — this skill is for import requests made directly to you.)
---

# Import SwiftUI → tango design canvas

You're inside a tango workspace. Turn the workspace's screen-level SwiftUI
views into design screens on the canvas, where the user can drag, resize, and
restyle them — then iterate with the live preview and export back via
\`export_run\`.

**Import is read-only on the Swift side. Do not edit, create, or delete any
\`.swift\` file during an import pass.**

## Playbook

### 1. Find the screens

\`Glob\` for \`**/*.swift\` from the workspace root. Skip:

- \`Pods/\`, \`.build/\`, \`DerivedData/\`, \`.swiftpm/\`, \`build/\`, \`.tango/\`
- \`*Tests*\`, \`Preview Content/\`, \`#Preview\` bodies, \`PreviewProvider\`s

\`TangoGenerated/\` is a special case: it's tango's own earlier exports of canvas
designs. Skip it when the canvas already has those screens (the canvas is the
source of truth). But when the canvas LOST them (cleared, fresh checkout) and
especially when the app's \`@main\` entry renders \`TangoGeneratedRootView\`,
re-import the \`Tango<Name>Screen.swift\` files at full fidelity — their
\`.frame(width:height:).offset(x:y:)\` coords are literal node geometry, the
\`tango:generated … screen=<id>\` header is the original screen id, and the
\`/// <Title> — WxH\` doc comment is the title + frame. Skip
\`TangoSupport.swift\` / \`TangoGeneratedIndex.swift\` (plumbing).

A "screen" is a top-level \`struct X: View\` that represents a full screen —
the \`@main\` App's root, \`NavigationStack\`/\`TabView\` destinations, sheet
contents. Leaf components (a row, a button style) are NOT screens; they render
as nodes inside their parent screen.

### 2. Translate each screen

Use the **SwiftUI → UINode cheat sheet in \`tango-swiftui\`**
(\`.claude/skills/tango-swiftui/SKILL.md\`) — same mapping, same coordinate
projection (walk containers, infer absolute coords from VStack/HStack/ZStack
axes, default frame 390×844 for iPhone-class apps).

One design screen per screen-level View. Use the View's type name as the
screen \`id\` and \`title\` (e.g. \`OnboardingView\`).

### 3. Write the spec

- Canvas empty (\`get_ui_mock\` → no screens)? \`set_ui_mock\` with all screens.
- Canvas has screens worth keeping? \`add_ui_screen\` per new screen.
- Set each emitted screen's \`sourceFile\` to the workspace-relative path of the
  .swift file it was translated from (omit for screens that don't mirror a
  single real file, and for TangoGenerated re-imports — the canvas keeps prior
  provenance when it's omitted).

### 4. Verify + record

Re-read with \`get_ui_mock\`: nodes inside frames, no empty Button/Badge text,
screen count matches what you found. Then
\`remember_note({ category: 'context', text: 'Imported N SwiftUI screens onto the canvas: <names>' })\`.

## Ownership rule (tell the user once, after the first import)

After import, the canvas is the design source of truth for these screens'
*look*. The user edits visually; you apply design changes back when they send
the design to you — don't redesign imported screens ad hoc in Swift. Files
under \`TangoGenerated/\` are tango-owned and regenerated on every
\`export_run\` — never hand-edit those.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

const CLAUDE_MD_SENTINEL_START = '<!-- tango:start (managed by tango — do not edit) -->';
const CLAUDE_MD_SENTINEL_END = '<!-- tango:end -->';
const CLAUDE_MD_BLOCK = `${CLAUDE_MD_SENTINEL_START}\n@.claude/tango.md\n${CLAUDE_MD_SENTINEL_END}`;
const AGENTS_MD_SENTINEL_START = '<!-- tango-codex:start (managed by tango — do not edit) -->';
const AGENTS_MD_SENTINEL_END = '<!-- tango-codex:end -->';

// First match only — second-pass `ensureWorkspace` calls should be idempotent.
// Multiline / dotall: `[\s\S]*?` non-greedy across lines.
const SENTINEL_RE = /<!-- tango:start[\s\S]*?<!-- tango:end -->/;
const AGENTS_SENTINEL_RE =
  /<!-- tango-codex:start[\s\S]*?<!-- tango-codex:end -->/;

export function mergeClaudeMd(existing: string | null): string {
  if (existing == null || existing === '') {
    return CLAUDE_MD_BLOCK + '\n';
  }
  if (SENTINEL_RE.test(existing)) {
    // Replace the first match in place. Trailing-newline behavior is preserved.
    return existing.replace(SENTINEL_RE, CLAUDE_MD_BLOCK);
  }
  // Append at end with one blank line separator. Normalize trailing whitespace
  // so we don't end up with three blank lines in a row.
  const trimmed = existing.replace(/\s*$/, '');
  return `${trimmed}\n\n${CLAUDE_MD_BLOCK}\n`;
}

function agentNeutralMarkdown(body: string): string {
  return body
    .replaceAll('Claude Code', 'Codex CLI')
    .replaceAll('terminal-Claude', 'terminal Codex')
    .replaceAll('Terminal-Claude', 'Terminal Codex')
    .replaceAll("Claude's", "Codex's")
    .replaceAll('Claude', 'Codex')
    .replaceAll('.claude/skills/', '.agents/skills/')
    .replaceAll('.claude/tango.md', 'AGENTS.md')
    .replaceAll('`.claude/tango.md`', '`AGENTS.md`')
    .replaceAll('CLAUDE.md', 'AGENTS.md');
}

function codexAgentsBlock(iosProject: IosProjectStatus, workspace: string): string {
  const body = agentNeutralMarkdown(tangoMd(iosProject, workspace))
    .replace(
      "You're running inside the **tango** workspace.",
      "You're running via Codex CLI inside the **tango** workspace.",
    )
    .replace(
      /---\n\nThis file is generated by tango[\s\S]*$/,
      [
        '---',
        '',
        'This block is generated by tango. Project-specific Codex instructions belong outside the managed tango-codex block.',
        '',
      ].join('\n'),
    );
  return `${AGENTS_MD_SENTINEL_START}\n${body.trimEnd()}\n${AGENTS_MD_SENTINEL_END}`;
}

export function mergeAgentsMd(
  existing: string | null,
  iosProject: IosProjectStatus,
  workspace: string,
): string {
  const block = codexAgentsBlock(iosProject, workspace);
  if (existing == null || existing === '') return block + '\n';
  if (AGENTS_SENTINEL_RE.test(existing)) {
    return existing.replace(AGENTS_SENTINEL_RE, block);
  }
  const trimmed = existing.replace(/\s*$/, '');
  return `${trimmed}\n\n${block}\n`;
}

const TANGO_SKILL_MDS: Array<[name: string, body: string]> = [
  ['tango-ui-mock', UI_MOCK_SKILL_MD],
  ['tango-ui-import', UI_IMPORT_SKILL_MD],
  ['tango-swiftui', SWIFTUI_SKILL_MD],
  ['tango-ios-sim', TANGO_IOS_SIM_SKILL_MD],
];

const CODEX_SKILL_DESCRIPTIONS: Record<string, string> = {
  'tango-ui-mock':
    'Build high fidelity shadcn and Tailwind UI designs on the Tango canvas. Use when the user asks to sketch prototype visualize design or mock a UI screen page or flow as editable components.',
  'tango-ui-import':
    'Import a workspace existing SwiftUI screens onto the Tango design canvas as editable screens. Use when the user asks to import load or bring their app screens into the editor.',
  'tango-swiftui':
    'Round trip a SwiftUI view through the Tango design canvas. Use when the user mentions SwiftUI a Swift view Xcode or a .swift file with show render mock sketch save write generate or update intent.',
  'tango-ios-sim':
    'Build install launch inspect drive and read logs for the workspace Xcode app on the booted iOS simulator via Tango MCP. Use for iOS Swift SwiftUI build run test simulator interaction and log prompts.',
};

function codexSkillMd(name: string, body: string): string {
  const neutral = agentNeutralMarkdown(body);
  const markdownBody = neutral.replace(/^---\n[\s\S]*?\n---\n*/, '');
  return [
    '---',
    `name: ${name}`,
    `description: ${CODEX_SKILL_DESCRIPTIONS[name]}`,
    '---',
    '',
    markdownBody,
  ].join('\n');
}

export type MergeOk = { ok: true; next: string };
export type MergeErr = { ok: false; reason: string };

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v);
}

export function mergeMcpJson(existing: string | null, port: number): MergeOk | MergeErr {
  let parsed: Record<string, unknown> = {};
  if (existing != null && existing.trim() !== '') {
    let raw: unknown;
    try {
      raw = JSON.parse(existing);
    } catch {
      return { ok: false, reason: 'existing .mcp.json is not valid JSON' };
    }
    if (!isPlainObject(raw)) {
      return { ok: false, reason: 'existing .mcp.json is not a JSON object' };
    }
    parsed = raw;
  }
  const servers = isPlainObject(parsed.mcpServers) ? { ...parsed.mcpServers } : {};
  servers['tango-canvas'] = {
    type: 'http',
    url: `http://localhost:${port}/mcp`,
  };
  const merged = { ...parsed, mcpServers: servers };
  return { ok: true, next: JSON.stringify(merged, null, 2) + '\n' };
}

export function mergeClaudeSettings(existing: string | null): MergeOk | MergeErr {
  let parsed: Record<string, unknown> = {};
  if (existing != null && existing.trim() !== '') {
    let raw: unknown;
    try {
      raw = JSON.parse(existing);
    } catch {
      return { ok: false, reason: 'existing .claude/settings.json is not valid JSON' };
    }
    if (!isPlainObject(raw)) {
      return { ok: false, reason: 'existing .claude/settings.json is not a JSON object' };
    }
    parsed = raw;
  }
  const env = isPlainObject(parsed.env) ? { ...parsed.env } : {};
  const merged = { ...parsed, env: { ...env, ...REQUIRED_CLAUDE_ENV } };
  return { ok: true, next: JSON.stringify(merged, null, 2) + '\n' };
}

async function readUtf8OrNull(p: string): Promise<string | null> {
  try {
    return await fs.readFile(p, 'utf8');
  } catch {
    return null;
  }
}

async function writeIfChanged(p: string, next: string): Promise<void> {
  const prev = await readUtf8OrNull(p);
  if (prev !== next) {
    await fs.writeFile(p, next);
  }
}

function codexWrapperSh(): string {
  return [
    '#!/bin/sh',
    'set -eu',
    '',
    'self_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"',
    'real="${TANGO_CODEX_REAL_BIN:-}"',
    'if [ -z "$real" ] || [ "$real" = "$0" ] || [ "$real" = "$self_dir/codex" ]; then',
    '  real=""',
    '  old_ifs="$IFS"',
    '  search_path="${PATH:-}"',
    '  IFS=:',
    '  for dir in $search_path; do',
    '    [ -z "$dir" ] && dir=.',
    '    [ "$dir" = "$self_dir" ] && continue',
    '    candidate="$dir/codex"',
    '    if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then',
    '      real="$candidate"',
    '      break',
    '    fi',
    '  done',
    '  IFS="$old_ifs"',
    'fi',
    '',
    'if [ -z "$real" ]; then',
    '  echo "tango: real codex executable not found" >&2',
    '  exit 127',
    'fi',
    '',
    'mcp_url="${TANGO_MCP_URL:-}"',
    'if [ -z "$mcp_url" ]; then',
    '  echo "tango: TANGO_MCP_URL is not set" >&2',
    '  exit 2',
    'fi',
    '',
    'exec "$real" \\',
    '  -c \'trust_level="trusted"\' \\',
    '  -c \'service_tier="fast"\' \\',
    '  -c "mcp_servers.tango-canvas.url=\\"$mcp_url\\"" \\',
    '  "$@"',
    '',
  ].join('\n');
}

export type EnsureError = { file: string; reason: string };
export type EnsureResult =
  | { ok: true }
  | { ok: false; errors: EnsureError[] };

// Set up our managed bits in `workspace`. Returns soft errors for each
// file we refused to write because it was malformed; we still write the
// pieces we own (.claude/tango.md, skills) and the CLAUDE.md sentinel
// block, so the workspace remains usable.
//
// This function does NOT update currentWorkspace; the caller (boot
// resolution / setWorkspace) is responsible for that.
export async function ensureWorkspace(
  port: number,
  workspace: string,
): Promise<EnsureResult> {
  const errors: EnsureError[] = [];

  await fs.mkdir(workspace, { recursive: true });
  await fs.mkdir(path.join(workspace, '.claude'), { recursive: true });
  await fs.mkdir(path.join(workspace, '.tango', 'bin'), { recursive: true });
  // Writes/migrates .tango/.gitignore so design.json (the persisted design
  // spec) is committable while DerivedData/ and bin/ stay ignored.
  await ensureTangoDir(workspace);
  await fs.mkdir(path.join(workspace, '.agents', 'skills'), { recursive: true });
  for (const [name] of TANGO_SKILL_MDS) {
    await fs.mkdir(path.join(workspace, '.claude', 'skills', name), {
      recursive: true,
    });
    await fs.mkdir(path.join(workspace, '.agents', 'skills', name), {
      recursive: true,
    });
  }

  // Mark detection in flight for this workspace, then reset the slot's
  // iOS state so MCP tools don't see a stale `detected` from the previous
  // workspace while detection runs against the new one. The `iosDetectionFor`
  // marker lets us drop our write-back if a newer ensureWorkspace took over
  // mid-detection (user clicked another workspace before this one finished).
  const detectionSlot = getSlot();
  detectionSlot.iosDetectionFor = workspace;
  _setIosProjectInternal({ kind: 'none' });
  // Run detection. The internal xcodebuild calls have their own timeouts
  // (30s for -list, 60s for -showBuildSettings), so this caps at ~90s for a
  // single project. Failures are surfaced via the slot, not thrown — a slow
  // xcodebuild shouldn't block server boot.
  let detected: IosProjectStatus;
  try {
    detected = await detectXcodeProject(workspace);
  } catch (err) {
    detected = {
      kind: 'error',
      message: err instanceof Error ? err.message : String(err),
    };
  }
  if (detectionSlot.iosDetectionFor === workspace) {
    _setIosProjectInternal(detected);
    detectionSlot.iosDetectionFor = null;
  }
  // else: another ensureWorkspace took over for a different workspace; let
  // its detection write the slot. We still write tango.md below for *this*
  // workspace's files (the file write target is workspace-local, no race).

  // .claude/tango.md — wholly ours, always overwrite. Splices in the iOS
  // section if detection found a project.
  await writeIfChanged(
    path.join(workspace, '.claude', 'tango.md'),
    tangoMd(detected, workspace),
  );

  // AGENTS.md — Codex reads this directly. Preserve user content outside our
  // managed block, mirroring the CLAUDE.md sentinel strategy.
  const agentsMdPath = path.join(workspace, 'AGENTS.md');
  const existingAgentsMd = await readUtf8OrNull(agentsMdPath);
  await writeIfChanged(
    agentsMdPath,
    mergeAgentsMd(existingAgentsMd, detected, workspace),
  );

  // .claude/skills/*/SKILL.md — wholly ours, always overwrite. Auto-discovered
  // by Claude Code; tuned playbooks for the design canvas (tango-ui-mock), the
  // SwiftUI round-trip (tango-swiftui), and the simulator dev loop
  // (tango-ios-sim). The .agents mirror carries the same playbooks with
  // Codex-facing paths and wording.
  for (const [name, body] of TANGO_SKILL_MDS) {
    await writeIfChanged(
      path.join(workspace, '.claude', 'skills', name, 'SKILL.md'),
      body,
    );
    await writeIfChanged(
      path.join(workspace, '.agents', 'skills', name, 'SKILL.md'),
      codexSkillMd(name, body),
    );
  }

  // .tango/bin/codex — workspace-local wrapper injected at the front of PATH
  // for Tango-owned PTYs. This covers users manually typing `codex`, while the
  // direct auto-launch path still passes the same session-scoped overrides.
  const codexWrapperPath = path.join(workspace, '.tango', 'bin', 'codex');
  await writeIfChanged(codexWrapperPath, codexWrapperSh());
  await fs.chmod(codexWrapperPath, 0o755);

  // Best-effort cleanup of retired skills in workspaces that were ensured by
  // older tango versions. They were wholly tango-managed, so removal is safe —
  // and load-bearing: a stale skill keeps advertising deleted MCP tools to the
  // terminal agent. Ignore any error (missing dir, permissions).
  const RETIRED_SKILLS = [
    'tango-codebase-sketch',
    'tango-ui-sketch',
    'tango-ios-map',
  ];
  for (const name of RETIRED_SKILLS) {
    for (const tree of ['.claude', '.agents'] as const) {
      await fs
        .rm(path.join(workspace, tree, 'skills', name), {
          recursive: true,
          force: true,
        })
        .catch(() => {});
    }
  }

  // CLAUDE.md — sentinel block, preserve everything else.
  const claudeMdPath = path.join(workspace, 'CLAUDE.md');
  const existingClaudeMd = await readUtf8OrNull(claudeMdPath);
  await writeIfChanged(claudeMdPath, mergeClaudeMd(existingClaudeMd));

  // .mcp.json — merge tango-canvas under mcpServers, preserve other servers.
  const mcpPath = path.join(workspace, '.mcp.json');
  const existingMcp = await readUtf8OrNull(mcpPath);
  const mcpResult = mergeMcpJson(existingMcp, port);
  if (mcpResult.ok) {
    await writeIfChanged(mcpPath, mcpResult.next);
  } else {
    errors.push({ file: '.mcp.json', reason: mcpResult.reason });
  }

  // .claude/settings.json — merge env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1.
  const settingsPath = path.join(workspace, '.claude', 'settings.json');
  const existingSettings = await readUtf8OrNull(settingsPath);
  const settingsResult = mergeClaudeSettings(existingSettings);
  if (settingsResult.ok) {
    await writeIfChanged(settingsPath, settingsResult.next);
  } else {
    errors.push({ file: '.claude/settings.json', reason: settingsResult.reason });
  }

  // tango-memory.md — create-if-absent; never overwrite. Pass the workspace
  // explicitly because in setWorkspace's flow this runs before the slot is
  // set, and ensureMemory() should never write into the *previous* workspace.
  try {
    await ensureMemory(workspace);
  } catch (err) {
    errors.push({
      file: 'tango-memory.md',
      reason: err instanceof Error ? err.message : String(err),
    });
  }

  return errors.length === 0 ? { ok: true } : { ok: false, errors };
}

// Boot resolution: env > persisted state > null. Called once from server.ts
// before app.prepare(). Returns the resolved workspace (or null if unset).
export async function resolveWorkspaceAtBoot(
  loadPersisted: () => Promise<string | null>,
): Promise<{ path: string | null; source: WorkspaceSource }> {
  const env = process.env.TANGO_WORKSPACE;
  if (env && env.trim() !== '') {
    const abs = path.resolve(env);
    _setWorkspaceInternal(abs, 'env');
    return { path: abs, source: 'env' };
  }
  const persisted = await loadPersisted();
  if (persisted) {
    try {
      const stat = await fs.stat(persisted);
      if (stat.isDirectory()) {
        _setWorkspaceInternal(persisted, 'persisted');
        return { path: persisted, source: 'persisted' };
      }
    } catch {
      // missing directory — fall through to unset
    }
  }
  _setWorkspaceInternal(null, 'unset');
  return { path: null, source: 'unset' };
}

// Re-export os.homedir for tests / future Electron swap.
export const _homedirForTests = os.homedir;
