import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ensureMemory } from './memory';
import { detectXcodeProject, type IosProjectStatus } from './iosBuild';

// The directory Claude operates in: where the in-app terminal lands, where
// `.mcp.json` and `.claude/tango.md` are managed so the `claude` CLI auto-
// discovers our canvas tools, and where `design-scratch/` PNGs land for the
// "Send to Claude" flow.
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
// `detectXcodeProject` can be spliced in. The HEAD covers canvas / UI-mock /
// SwiftUI design flows; the iOS section (when present) covers the build /
// install / launch loop on the booted simulator; the TAIL is the workspace
// memory section + footer.
const TANGO_MD_HEAD = `# Designer canvas (tango)

You're running inside the **tango** workspace. The user is viewing an Excalidraw canvas in the left pane of their browser; this terminal is in the right pane. The \`tango-canvas\` MCP server lets you read and modify that canvas:

- \`get_canvas_state\` — read the current scene (elements + appState; embedded image bytes elided)
- \`set_canvas_state\` — replace the entire scene
- \`add_elements\` — append elements without disturbing existing ones
- \`clear_canvas\` — empty the scene
- \`screenshot_canvas\` — see the rendered canvas as an image (call this before proposing wireframes, critiques, or anything that depends on what the user has drawn — \`get_canvas_state\` strips embedded image bytes, this gives you the actual pixels)

Reach for these whenever the user asks for visual work — wireframes, diagrams, sketches, layout proposals. Prefer \`add_elements\` when annotating or extending; \`set_canvas_state\` for a full redesign. Element shape matches Excalidraw's \`serializeAsJSON\` output — call \`get_canvas_state\` first if you need to see the shape.

The same MCP server also exposes **UI mock tools** for tango's "UI" mode — a higher-fidelity surface where the user sees real shadcn/Tailwind components instead of an Excalidraw wireframe, and can drag/resize/text-edit them directly:

- \`get_ui_mock\` — read the current shadcn-based UI mock spec (call this first; user tweaks live here)
- \`get_ui_viewport\` — read the live pixel size of the user's UI panel; use it as the default frame size for new screens so the mock fills exactly what they see
- \`set_ui_mock\` — replace the whole spec (one or more screens of absolutely-positioned nodes)
- \`add_ui_screen\` — append a screen to an existing flow without touching the others
- \`clear_ui_mock\` — empty the spec

For UI sketching ("sketch my UI", "wireframe this screen", "draw a layout for X"), follow the **\`tango-ui-sketch\`** skill at \`.claude/skills/tango-ui-sketch/SKILL.md\` — it turns a UI into an Excalidraw wireframe (structure, no pixels).

For higher-fidelity UI prototyping ("mock my UI in shadcn", "show me what the X screen would look like", "build a UI mock of Y", "prototype this flow"), follow the **\`tango-ui-mock\`** skill at \`.claude/skills/tango-ui-mock/SKILL.md\` instead — it transcribes a real production UI into the shadcn-based mock surface, where the user can drag, resize, and edit text, and then ship the tweaks back as a reference for the production codebase. Use \`tango-ui-mock\` when the user wants to *visualize and tweak* a UI; \`tango-ui-sketch\` when they want a wireframe.

For round-tripping a **SwiftUI** view through the canvas — read a \`.swift\` file and render it on the canvas, let the user tweak it, then regenerate SwiftUI back into the same file — follow the **\`tango-swiftui\`** skill at \`.claude/skills/tango-swiftui/SKILL.md\`. It picks UI mock (default) or sketch mode internally and edits the \`.swift\` file the user has selected. Triggers on any prompt naming a \`.swift\` file, SwiftUI, Xcode, or a Swift View together with read / show / render / mock / sketch / save / write / generate intents.

For mapping the **whole iOS app** as a Figma-style screen-flow diagram on the canvas ("map out my iOS app", "show me all the screens", "draw the navigation graph") — follow the **\`tango-ios-map\`** skill at \`.claude/skills/tango-ios-map/SKILL.md\`. It scans \`.swift\` and \`.storyboard\` sources, builds a screens + edges graph, and calls the \`set_screen_flow\` MCP tool to lay it out and draw it. Distinct from \`tango-swiftui\` (one screen) and \`tango-ui-sketch\` (one wireframe).

Edits via these tools appear on the user's canvas immediately. The user can \`Cmd+Z\` your changes, and their edits flow back so \`get_canvas_state\` always reflects what's on their screen right now.

For visual context, prefer \`screenshot_canvas\` — it's the live channel. The user may also drop a PNG into \`design-scratch/\` and ping you with a \`# review design at design-scratch/...png\` comment line; that's the deliberate-handoff channel — read the file when they point you at it.

`;

const TANGO_MD_TAIL = `## Workspace memory

A live memory file lives at \`./tango-memory.md\` — read it now for prior context (snapshots taken, agent runs, recorded design decisions). When the user states a design decision, constraint, or context worth keeping for future sessions, call the \`remember_note\` MCP tool with the appropriate \`category\` (\`'decision'\`, \`'context'\`, or \`'todo'\`). Don't edit the Summary or Recent sections of \`tango-memory.md\` directly — those are managed by tango. Your own working notes go in the \`Notes (yours)\` block at the bottom, which tango never touches. Note: snapshot captions and recorded notes are summarized via the same OpenAI key as the controller agent.

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

Build, install, and launch the app on that simulator with the \`tango-canvas\` MCP tools — \`ios_status\` (sanity-check the project + booted devices), \`ios_build_run\` (atomic build → install → launch), \`ios_logs_recent\` (read the running app's recent log output). \`ios_build_run\` is the headline tool. The build is incremental, so it's the closest thing to hot reload without source modifications. ${skillRef}

**Rule:** any time you edit a \`.swift\` file in this workspace, immediately load the \`tango-ios-sim\` skill and call \`ios_build_run\` to reload the simulator. The user is watching it — design changes don't exist for them until the running app reflects them. Don't wait for the user to ask, don't batch edits silently, don't skip the rebuild because "they'll see it next time."

`;
  }

  // ambiguous
  const list = status.candidates
    .map((c) => `\`${path.relative(workspace, c.projectPath) || path.basename(c.projectPath)}\``)
    .join(', ');
  return `## iOS simulator

This workspace contains multiple Xcode projects (${list}) and tango couldn't pick one automatically. Call \`ios_status\` first to see the candidates and their schemes, then pass an explicit \`scheme\` (and \`udid\` if multiple simulators are booted) to \`ios_build_run\`. The booted iOS simulator is iframed into the right sidebar via \`serve-sim\`. ${skillRef}

**Rule:** any time you edit a \`.swift\` file, load the \`tango-ios-sim\` skill and call \`ios_build_run\` (with the resolved \`scheme\`) to reload the simulator. The user is watching it — design changes don't exist for them until the running app reflects them.

`;
}

export function tangoMd(
  iosProject: IosProjectStatus,
  workspace: string,
): string {
  return TANGO_MD_HEAD + renderIosSection(iosProject, workspace) + TANGO_MD_TAIL;
}

// Skill body for `${workspace}/.claude/skills/tango-ui-sketch/SKILL.md`.
// Auto-discovered by Claude Code from `.claude/skills/<name>/SKILL.md` and
// invocable both as a slash command (`/tango-ui-sketch`) and via the model's
// auto-invocation against the `description` field. Wholly tango-managed,
// same overwrite policy as `.claude/tango.md`. Description is intentionally
// broad on triggers (sketch / wireframe / mock up / lay out / draw / design,
// applied to UI / screen / page / interface) so prompts like "sketch my UI"
// reliably auto-invoke it.
const UI_SKETCH_SKILL_MD = `---
name: tango-ui-sketch
description: Sketch a UI as a wireframe on the tango Excalidraw canvas. Use whenever the user asks to sketch, wireframe, mock up, lay out, draw, or design a UI / screen / page / view / layout / interface — whether the UI already exists in the codebase, the user describes it in words, or you're proposing alternatives. This is the default skill for any "sketch / draw / wireframe / mock up X" prompt where X is a UI surface.
---

# UI → wireframe sketch

You're inside a tango workspace, so the user is staring at an Excalidraw canvas in their left pane. Your job: turn a UI into a clean, labeled wireframe on that canvas — structure first, pixels never. The UI you're sketching is one of:

- **The current app's UI** ("sketch my UI", "draw the to-do screen on the canvas") — extract it from the codebase.
- **A described UI** ("wireframe a settings page with two tabs") — build it from the user's spec, asking one quick question if intent is genuinely ambiguous.
- **A redesign / alternative** ("rework this", "propose a different layout") — capture the current shape first, then sketch the alternative alongside.

Use the \`tango-canvas\` MCP tools (already loaded): \`get_canvas_state\`, \`add_elements\`, \`set_canvas_state\`, \`clear_canvas\`, \`screenshot_canvas\`.

## Playbook

### 1. Figure out what you're sketching
- **From the codebase.** Find the entry-point page (\`src/app/page.tsx\`, \`pages/index.tsx\`, \`App.tsx\`, the relevant route file). \`Read\` it and one level of the components it composes — enough to enumerate the visible regions (header, nav, main content, sidebar, footer) and the controls inside them. Stop as soon as you can list them.
- **From a description.** Write down the regions and controls in one sentence each before drawing. If the user gave you ambiguous scope (mobile vs desktop? logged-in vs logged-out? what content lives on the screen?), ask one tight clarifying question — don't draw three variants speculatively.
- **From a reference on the canvas.** \`screenshot_canvas\` first to see what's already drawn; treat that as the reference.

### 2. Don't trample the canvas
\`get_canvas_state\` first. If it has existing elements:
- **Default**: use \`add_elements\` and place the new wireframe in empty space below or to the right of existing content.
- Ask the user before \`clear_canvas\` or \`set_canvas_state\` — those wipe their work. Phrase it: *"There's already content on the canvas — clear it, or place the wireframe alongside?"*

If the canvas is empty, go straight to \`add_elements\`.

### 3. Pick a frame
Wireframes live inside an outer frame so the screen edge is visible:

| Form factor | Frame size |
|-------------|------------|
| Mobile      | \`360 × 720\` |
| Tablet      | \`768 × 1024\` |
| Desktop     | \`1280 × 800\` |

Origin around \`(100, 100)\`. If you're drawing multiple screens (a flow), lay frames left-to-right with **80px gutters** and label each frame above it (\`text\` at \`y = frame.y - 32\`, \`fontSize: 18\`).

### 4. Lay out regions, then controls
Build the wireframe in two passes so the structure is legible before the detail goes in.

**Pass A — regions.** Carve the frame into header / nav / main / sidebar / footer or whatever the screen actually has. Use **inset rectangles** with a 16px gutter from the frame edge and 12–16px gutters between regions. Label each region (\`Header\`, \`Nav\`, \`Feed\`, etc.).

**Pass B — controls.** Inside each region, place the actual controls: buttons, inputs, list rows, cards, avatars, copy. Use the building blocks below.

### 5. Element shapes
Element JSON matches Excalidraw's \`serializeAsJSON\` output. Permissive — extra fields are fine, missing fields default. **If unsure, call \`get_canvas_state\` first and copy the field set you see.**

**Frame** (outer screen rectangle):
\`\`\`json
{ "type": "rectangle", "id": "frame-1", "x": 100, "y": 100, "width": 360, "height": 720,
  "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
  "strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "angle": 0,
  "roundness": { "type": 3 } }
\`\`\`

**Region** (rectangle + label):
\`\`\`json
[
  { "type": "rectangle", "id": "header", "x": 116, "y": 116, "width": 328, "height": 56,
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "angle": 0 },
  { "type": "text", "id": "header-label", "x": 132, "y": 132, "width": 200, "height": 24,
    "text": "Header", "fontSize": 18, "fontFamily": 1, "textAlign": "left",
    "verticalAlign": "top", "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
    "opacity": 100, "angle": 0 }
]
\`\`\`

**Button** (rounded rectangle + centered label):
\`\`\`json
[
  { "type": "rectangle", "id": "btn-primary", "x": 132, "y": 644, "width": 296, "height": 44,
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "angle": 0,
    "roundness": { "type": 3 } },
  { "type": "text", "id": "btn-primary-label", "x": 132, "y": 654, "width": 296, "height": 24,
    "text": "Primary action", "fontSize": 16, "fontFamily": 1, "textAlign": "center",
    "verticalAlign": "top", "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
    "opacity": 100, "angle": 0 }
]
\`\`\`

**Input** (rectangle + placeholder text):
\`\`\`json
[
  { "type": "rectangle", "id": "input-email", "x": 132, "y": 220, "width": 296, "height": 40,
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "angle": 0,
    "roundness": { "type": 3 } },
  { "type": "text", "id": "input-email-ph", "x": 144, "y": 230, "width": 200, "height": 20,
    "text": "Email", "fontSize": 14, "fontFamily": 1, "textAlign": "left",
    "verticalAlign": "top", "strokeColor": "#7a7a7a", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
    "opacity": 100, "angle": 0 }
]
\`\`\`

**Body / list-row placeholder** (horizontal line — stand-in for one line of copy):
\`\`\`json
{ "type": "line", "id": "ph-1", "x": 132, "y": 280, "width": 240, "height": 0,
  "points": [[0,0],[240,0]], "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
  "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
  "opacity": 100, "angle": 0 }
\`\`\`

**Image / avatar placeholder** (rectangle with diagonal lines — convention for "image goes here"):
\`\`\`json
[
  { "type": "rectangle", "id": "avatar", "x": 132, "y": 132, "width": 40, "height": 40,
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "angle": 0,
    "roundness": { "type": 3 } },
  { "type": "line", "id": "avatar-x1", "x": 132, "y": 132, "width": 40, "height": 40,
    "points": [[0,0],[40,40]], "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
    "opacity": 100, "angle": 0 },
  { "type": "line", "id": "avatar-x2", "x": 132, "y": 132, "width": 40, "height": 40,
    "points": [[40,0],[0,40]], "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
    "opacity": 100, "angle": 0 }
]
\`\`\`

### 6. Style rules (load-bearing for legibility)
- **Wireframe palette.** One stroke color (\`#1e1e1e\`); placeholder text in \`#7a7a7a\`. **No fills.** No decorative color.
- **\`roughness: 0\` everywhere.** Excalidraw's hand-drawn look fights legibility for wireframes; clean lines read as structure.
- **Label every region.** Unlabeled boxes are noise. Controls don't need labels if their shape is conventional (buttons do; placeholder lines don't).
- **Axis-aligned only.** No diagonal arrows or rotated rectangles. The diagonals on avatar placeholders are the only exception.
- **Text \`x/y\` ≈ container \`x+12, y+10\`** for inputs and small controls; \`x+16, y+16\` for region headers. Keep text inside its container's bounding box.
- **Type sizes**: \`14\` for body / placeholder, \`16\` for button labels, \`18\` for region headers, \`24\` for screen title (above the frame).
- **One \`add_elements\` call** with all elements when you can — it's cheaper and atomic on undo.

### 7. Inspect, then iterate
\`add_elements\` / \`set_canvas_state\` return a JSON result with \`written.elementCount\` and a \`diagnostics\` block. If \`diagnostics.emptyText\` is empty, the write was clean — you're done. If it's non-empty, you wrote a \`text\` element with no \`text\` field; fill it in and re-call.

For *layout* issues that JSON can't catch (boxes overlapping, labels clipped, regions drifting out of alignment), call \`screenshot_canvas\` only when (a) the user explicitly asked to see the result, (b) the diagnostics flagged something you can't reason about from the JSON, or (c) the wireframe is unusually complex (≥3 screens or dense overlap risk). Otherwise the screenshot round-trip is wasted latency.

When you do iterate, recompute coords and \`set_canvas_state\` to fix.

### 8. Record it
Call \`remember_note({ category: 'context', text: 'Sketched UI: <one-line shape, e.g. "Mobile to-do screen — header, list, FAB">' })\`. Future sessions will see this in \`tango-memory.md\`.

## Anti-patterns
- Don't chase pixel-perfection or visual fidelity. Wireframes are about structure.
- Don't add fills, brand colors, or icons. Stroke and text only.
- Don't draw what the user didn't ask for. "Sketch the login screen" means one screen, not three.
- Don't \`clear_canvas\` without asking.
- Don't reach for \`screenshot_canvas\` reflexively — inspect the write result's \`diagnostics\` block first; only screenshot when the user asked or diagnostics flagged a layout issue.
- Don't try to draw architecture diagrams here — for "diagram my codebase" / "draw the architecture" prompts, you don't need a skill: use the canvas tools directly with rectangles + arrows for modules and edges.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Skill body for `${workspace}/.claude/skills/tango-ui-mock/SKILL.md`.
// Drives terminal-Claude through tango's "UI" mode: read the production UI
// from the codebase, transcribe it into a shadcn-based mock spec via the
// `set_ui_mock` MCP tool, then read user tweaks back via `get_ui_mock` after
// the user has dragged / resized / edited the mock and pinged Claude.
// Wholly tango-managed, same overwrite policy as `.claude/tango.md`.
const UI_MOCK_SKILL_MD = `---
name: tango-ui-mock
description: Build a high-fidelity shadcn/Tailwind UI mock on the tango "UI" panel for the user to drag, resize, and tweak — then read their changes back as a reference for the production codebase. Use whenever the user asks to mock up, prototype, visualize, or "see what X would look like" for a UI / screen / page / flow as a real shadcn-based prototype (not a wireframe). Use \`tango-ui-sketch\` instead when they want a wireframe.
---

# UI mock (shadcn / Tailwind)

You're inside a tango workspace. When the user is in the "UI" mode tab, the left pane is a fixed-frame mock canvas where shadcn-styled components sit at absolute pixel coordinates. The user can drag, resize, multi-select, and double-click-to-edit-text. Your job is two-way:

1. **Down**: turn a production UI (existing in the codebase, or described by the user) into a mock spec that visualizes it.
2. **Up**: when the user has tweaked the mock and pinged you (typically by clicking "Send to Claude" — you'll see a markdown handoff in the terminal), read the current spec via \`get_ui_mock\` and translate the deltas into responsive Tailwind / shadcn changes in the production source.

This is not a wireframe surface (use \`tango-ui-sketch\` for that). The mock renders real shadcn primitives — Button, Input, Badge, Separator, Textarea — plus layout primitives (\`div\`, \`text\`, \`heading\`, \`Image\`, \`Icon\`).

## Tools

\`get_ui_mock\`, \`get_ui_viewport\`, \`set_ui_mock\`, \`add_ui_screen\`, \`clear_ui_mock\` (from the \`tango-canvas\` MCP server, same as the canvas tools). The spec shape:

\`\`\`ts
type UISpec = { screens: UIScreen[] };
type UIScreen = {
  id: string;          // stable, human-readable: 'login', 'dashboard'
  title: string;       // shown above the frame in the panel
  frame: { w: number; h: number };  // pixels
  nodes: UINode[];
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

### 7. Inspect the result

\`set_ui_mock\` / \`add_ui_screen\` return a JSON result with \`written\` counts and a \`diagnostics\` block. If both \`diagnostics.frameOverflows\` and \`diagnostics.emptyText\` are empty arrays, the write was clean — tell the user, you're done.

If \`diagnostics.frameOverflows\` is non-empty, one or more nodes spill outside the screen frame (negative x/y or x+width > frame.w / y+height > frame.h). Fix the coords and re-call. If \`diagnostics.emptyText\` is non-empty, you wrote a \`Button\` / \`Badge\` / \`heading\` / \`text\` with no \`text\` field — fill it in.

You do NOT need to re-call \`get_ui_mock\` to verify a clean write — the diagnostics already cover what the round-trip used to catch. Only call \`screenshot_canvas\` if the user asked to see the result or you suspect a visual issue the spec JSON can't reveal.

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
- Don't import \`@excalidraw/excalidraw\` or use the canvas tools here — \`tango-ui-sketch\` is the wireframe path.
- Don't ignore the \`diagnostics\` block in the write tool's result. Empty arrays = clean; non-empty = fix and re-call.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Skill body for `${workspace}/.claude/skills/tango-swiftui/SKILL.md`.
// Round-trips a SwiftUI View through tango's canvas: read a `.swift` file and
// render it as a UI mock (default) or wireframe sketch (on request); the user
// drags / resizes / edits; then regenerate SwiftUI back into the same file.
// All driven from terminal-Claude — no new tango UI surfaces. Wholly tango-
// managed, same overwrite policy as `.claude/tango.md`. Description is broad
// on triggers (any prompt naming `.swift` / SwiftUI / Xcode + read/show/save/
// write/render/mock/sketch intents) so it auto-invokes reliably.
const SWIFTUI_SKILL_MD = `---
name: tango-swiftui
description: Round-trip a SwiftUI View through tango's canvas — when a \`.swift\` file or SwiftUI source is involved. Use whenever the user mentions SwiftUI, Swift View, \`.swift\`, or Xcode together with intents to read, show, render, mock, sketch, visualize, save, write, generate, or update the design. Internally picks UI mock (default, high-fidelity shadcn nodes) or sketch mode (Excalidraw wireframe) per user request and source complexity. Use \`tango-ui-mock\` / \`tango-ui-sketch\` instead when the UI is generic web/React, not SwiftUI.
---

# SwiftUI ↔ tango canvas

You're inside a tango workspace. The user has a SwiftUI view (in a \`.swift\` file) that they want to see, edit visually, and write back. Two flows:

1. **Read**: turn a \`.swift\` source file into a tango canvas — UI mock by default (high-fidelity shadcn primitives) or sketch (Excalidraw wireframe) on request.
2. **Write**: turn the current canvas back into SwiftUI source and update the file the user has selected.

Both flows live in this terminal-Claude session. The user does not see SwiftUI buttons in tango's UI — the canvas just reflects whatever you push to it via MCP, and you regenerate the \`.swift\` source when they ping you.

## Tools

You'll combine your filesystem tools with tango's MCP tools:

- **Filesystem (built-in)**: \`Read\` / \`Write\` / \`Edit\` / \`Glob\` for \`.swift\` files.
- **UI mock (\`tango-canvas\` MCP)**: \`get_ui_mock\`, \`set_ui_mock\`, \`clear_ui_mock\`, \`get_ui_viewport\`, \`add_ui_screen\`. Spec shape is \`{screens: [{id, title, frame:{w,h}, nodes: UINode[]}]}\` — see \`.claude/skills/tango-ui-mock/SKILL.md\` for the full schema, type union, and per-type \`props\`.
- **Sketch (\`tango-canvas\` MCP)**: \`get_canvas_state\`, \`set_canvas_state\`, \`add_elements\`, \`clear_canvas\`, \`screenshot_canvas\`. Element JSON matches Excalidraw's \`serializeAsJSON\` output — see \`.claude/skills/tango-ui-sketch/SKILL.md\` for the shape conventions and the wireframe palette.

## Pick the mode

- **UI mock by default.** When the SwiftUI uses stock components (\`Button\`, \`Text\`, \`TextField\`, \`Image\`, \`Divider\`, …) the structured node graph maps cleanly and the user can edit it like a real UI.
- **Sketch only** when the user explicitly says "wireframe" / "sketch", or when the source uses heavy custom drawing (\`Path\`, \`Canvas\`, complex \`GeometryReader\` math) that the UI mock node types can't represent. Sketch mode is lower fidelity — the goal is structure, not pixel match.
- The user may ask for both (mock for editing, sketch as a structural overview). Push to both panels in the same turn when they do.

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

For sketch mode: same idea, but you build labeled Excalidraw rectangles + text annotations per \`tango-ui-sketch\`'s shape conventions. Looser fidelity. The label inside each shape is the SwiftUI view name (e.g. \`Button "Sign in"\`, \`TextField "Email"\`).

### 4. Pick a frame

**Default to iPhone proportions** — SwiftUI views are iOS-first, and the user's UI panel is wider-than-tall, so using the raw viewport produces a 16:9 frame that doesn't match how the view will actually render on device.

- **Default**: \`390×844\` (iPhone 15 logical size). If the panel is taller (call \`get_ui_viewport\` to check), scale proportionally — keep the ~9:19.5 ratio, e.g. \`{ w: viewport.w, h: Math.round(viewport.w * 844 / 390) }\` capped at the viewport height.
- **iPad**: \`820×1180\` (iPad Air) if the source uses iPad-only modifiers (\`.navigationSplitViewStyle\`, \`NavigationSplitView\`, \`.regular\` size class checks) or the user mentions iPad.
- **Mac**: only fall back to the raw \`get_ui_viewport\` size when the source is clearly a macOS app (\`WindowGroup\` with macOS modifiers, \`.frame(minWidth: 800, minHeight: 600)\` style desktop sizing) or the user explicitly says "Mac".

### 5. Push it

UI mock: \`set_ui_mock({ spec: { screens: [{ id, title, frame, nodes }] } })\`. Use the file's stem as both \`id\` and \`title\` (e.g. \`OnboardingView\`). One screen per top-level View; if the file declares multiple Views, emit a screen per View.

Sketch: \`get_canvas_state\` first to avoid trampling existing work; then \`add_elements\` (default) or \`set_canvas_state\` (with explicit user OK).

### 6. Inspect the result

\`set_ui_mock\` / \`add_ui_screen\` (and \`set_canvas_state\` / \`add_elements\` in sketch mode) return a JSON result with \`written\` counts and a \`diagnostics\` block. If \`diagnostics.frameOverflows\` and \`diagnostics.emptyText\` are both empty, the spec is clean — tell the user.

When the diagnostics flag overflows, you've likely picked the wrong frame size for an iOS view in a wide browser pane. Recompute against the iPhone-proportions default and re-call. When the diagnostics flag empty text, you skipped a label — fill it in.

You do NOT need to re-read via \`get_ui_mock\` / \`get_canvas_state\` to verify a clean write. Only \`screenshot_canvas\` (sketch mode) for layout doubts the JSON can't resolve.

## Write flow (tango → \`.swift\`)

### 1. Identify the target file

In priority order: the path the user named in this turn → the \`.swift\` file you most recently \`Read\` in this conversation → ask the user. Don't invent a brand-new path without confirming.

### 2. Read the canvas

UI mock: \`get_ui_mock\`. The spec is canonical — the user has likely dragged / resized / edited text since you last set it.

Sketch: \`screenshot_canvas\` for pixel context **plus** \`get_canvas_state\` for shape JSON. Reason from both. Lower fidelity is acceptable; ask the user to confirm before overwriting.

### 3. Infer SwiftUI containers from positions

UI mock siblings are absolutely positioned — you have to recover the SwiftUI layout. Cluster them:

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

The full per-view mapping (every supported SwiftUI primitive, every modifier, every node \`type\`) lives in **\`.claude/skills/tango-swiftui/_reference/mappings.md\`**. \`Read\` it the first time you read or write SwiftUI in a session — once is enough; cache it mentally and re-skim only when you hit a primitive you haven't placed yet. Common cases you can do from memory:

| SwiftUI                                | UINode                              |
|----------------------------------------|-------------------------------------|
| \`Text("…")\`                           | \`text\` (or \`heading\` if \`.largeTitle\`/\`.title\`) |
| \`Button("…") { }\`                     | \`Button\` + \`text\` + \`props.variant\`  |
| \`TextField\` / \`SecureField\`           | \`Input\` + \`props.placeholder\`       |
| \`TextEditor\`                          | \`Textarea\` + \`props.placeholder\`    |
| \`Image(systemName:)\` / \`Image("…")\`   | \`Icon\` (with \`props.iconName\`) / \`Image\` |
| \`Divider()\`                           | \`Separator\` (axis from container)    |
| \`VStack\` / \`HStack\` / \`ZStack\`        | (no node — translate via coords)    |

**Anything not in this 7-row table — \`Toggle\`, \`Picker\`, \`Slider\`, \`Stepper\`, \`DatePicker\`, \`ColorPicker\`, \`ProgressView\`, \`List\`/\`ForEach\` rows, off-theme color/font/background modifiers — \`Read\` \`_reference/mappings.md\` before guessing.** Those primitives have specific placeholder rules and \`remember_note\` stash conventions that the in-body table doesn't carry.

For UINode → SwiftUI: the inverse mapping plus container inference (Write flow §3) — same reference file. Layout-affecting CSS keys in \`style\` (\`position\`, \`top\`, \`left\`, etc.) are dropped by the renderer; infer SwiftUI layout from coords, not from CSS hints.

### Sketch mode notes

Treat each leaf SwiftUI view as a labeled rectangle in the wireframe. Use \`tango-ui-sketch\`'s shape vocabulary (frame rectangle, region rectangles, button shapes, input shapes, placeholder lines, avatar-with-X). Container views mark off regions. The label inside each shape is the SwiftUI view name. One stroke color, no fills, \`roughness: 0\`.

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

- Don't try to render arbitrary SwiftUI in the UI mock when sketch mode would be more honest. Heavy custom views look broken as a \`Button\` placeholder.
- Don't ship absolute-positioned SwiftUI back to the file. Use \`VStack\`/\`HStack\`/\`ZStack\` inferred from sibling clustering; coords are visualization, not implementation.
- Don't write to \`.swift\` files outside the workspace without checking with the user — paths the user named are fine; paths you guessed are not.
- Don't put off-theme colors in \`className\` — Tailwind JIT can't see runtime arbitrary values; always use the \`style\` field.
- Don't claim "done" until both \`diagnostics.frameOverflows\` and \`diagnostics.emptyText\` arrays are empty (read) or you've shown the diff (write).

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
description: Build the workspace's Xcode project, install the resulting .app on the booted iOS simulator, and launch it — the dev loop for iterating on a SwiftUI / UIKit app while the user watches the simulator iframed in tango's right sidebar. Use whenever the user says "build", "run", "launch", "install", "rebuild", "deploy", "compile", "ship", "preview", "try it", "test on the sim", "push to sim", "open in simulator", "iterate", "see the change", "fix the build", or "why isn't it building" in an iOS / Xcode / Swift / SwiftUI context, and especially after the user has accepted a Swift edit you proposed. Also use for log investigation prompts ("check the logs", "what's the app saying", "any crashes"). Distinct from \`tango-swiftui\` (which round-trips a SwiftUI View through tango's canvas without ever building).
---

# iOS build / install / launch loop

You're inside a tango workspace whose Xcode project tango has already detected (see the "iOS simulator" section in your \`.claude/tango.md\`). The user has the booted iOS simulator iframed into the right sidebar via \`serve-sim\` — they're literally watching the app run while you edit. Your job: take whatever Swift edits land and get the running app on the simulator to reflect them, fast.

## Tools

The \`tango-canvas\` MCP server exposes three tools for this loop:

- \`ios_status\` — fast read-only check. Returns \`{ project, bootedDevices, activeDeviceUdid }\`. \`project\` mirrors what's in \`tango.md\`; \`bootedDevices\` lists everything \`xcrun simctl list devices booted\` reports; \`activeDeviceUdid\` is the simulator the iframe is showing (from \`serve-sim\`'s \`/.sim/api\`) so your build targets the same device the user is looking at.
- \`ios_build_run\` — the headline tool. Atomic \`xcodebuild\` → \`simctl install\` → \`simctl terminate\` → \`simctl launch\`. Inputs are all optional: \`scheme\`, \`udid\`, \`configuration\` (Debug / Release; default Debug), \`bringForeground\` (default true; terminates the running app before launch so it relaunches with the new binary).
- \`ios_logs_recent\` — calls \`xcrun simctl spawn <udid> log show\` with a predicate scoped to the running app's bundle id and process name. Use after \`ios_build_run\` if the user reports unexpected runtime behavior.

\`tango-canvas\` also exposes the canvas / UI mock / SwiftUI-round-tripping tools — those are for *design*, not *running*. If the user wants to see a SwiftUI file on the canvas, that's \`tango-swiftui\`. If they want to run the app, that's this skill.

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
- **Don't try to drive simulator gestures (tap / swipe / rotate / open URL) yet** — those tools aren't built. If the user asks, tell them it's coming; for now they tap on the iframe themselves.
- **Don't add Inject without explicit user approval.** It modifies source. Quote the setup, wait for the green light.

## Record it

After the **first** successful build for a workspace, ever, record the cadence: \`remember_note({ category: 'context', text: 'iOS dev loop: scheme <Scheme>, device <Device>; rebuild ~Ns for small edits' })\`. \`Read\` \`tango-memory.md\` first to check for an existing entry — don't add a duplicate on every session start.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Skill body for `${workspace}/.claude/skills/tango-ios-map/SKILL.md`. Macro
// view: scan all .swift / .storyboard files in the workspace, extract a
// {screens, edges} graph, hand it to the `set_screen_flow` MCP tool which
// runs layered layout + draws the diagram on the Excalidraw canvas. Distinct
// from `tango-swiftui` (single-View round-trip) and `tango-ui-sketch` (single
// UI wireframe). Wholly tango-managed, same overwrite policy as siblings.
const TANGO_IOS_MAP_SKILL_MD = `---
name: tango-ios-map
description: Use **this skill — not \`tango-ui-sketch\`, \`tango-ui-mock\`, or \`tango-swiftui\`** — whenever the user wants their *whole iOS app's screens at once* (multiple screens) on tango's canvas, even if the prompt says "sketch", "mock", or "UI mode". Renders all screens of a Swift / SwiftUI / UIKit / Xcode app as a Figma-style flow diagram. Triggers: "map out my iOS app", "show me all the screens", "draw the navigation graph", "diagram the screen flow", "what does my app look like as a flow", "show me the X flow", "bring my iOS app into sketch mode". For a *single* UI use \`tango-ui-sketch\` / \`tango-ui-mock\`; for one \`.swift\` View round-trip use \`tango-swiftui\`.
---

# iOS app → screen-flow diagram

Render the user's whole iOS app as a labeled-card flow diagram on tango's Excalidraw canvas: one card per screen, kind-colored arrows for navigation, the entry point highlighted. Best-effort heuristic parsing — partial graphs are valuable; perfect is not the bar.

Two MCP tool calls do the whole job: \`scan_ios_app\` (server-side regex over \`.swift\` / \`.storyboard\`) hands you the \`{screens, edges}\` graph; \`set_screen_flow\` lays it out and draws it. You don't need to \`Read\` Swift files for this — the scanner already did.

## Tools

- \`ios_status\` — confirm there's a detected Xcode project before scanning. Bail with a friendly message if not.
- \`get_canvas_state\` — check the canvas isn't already showing the user's work.
- \`scan_ios_app\` — server-side scan. Returns \`{ screens, edges, scannedFiles, cachedFiles, skippedDirs }\`. Skips \`Pods/\`, \`.build/\`, \`DerivedData/\`, \`*.xcassets/\`, \`*Tests*\`, \`Preview Content/\`, \`*Previews.swift\` automatically. Cached by file mtime — re-runs after small edits only read changed files. Pass \`includeSummaries: true\` for one-line per-screen summaries (slightly slower).
- \`set_screen_flow\` — single tool call, full graph. Input mirrors \`scan_ios_app\`'s output, plus an optional \`options\` field: \`{ append?, cardWidth?, cardHeight?, origin?: {x,y} }\`. Default replaces the canvas.
- \`screenshot_canvas\` — verify the diagram on the rare occasion the JSON alone isn't enough.
- \`remember_note\` — record the macro shape so future sessions know.

## Playbook

### 1. Precondition: detect the Xcode project

Call \`ios_status\` first.

- \`project.kind === 'none'\`: no Xcode project here. Tell the user — they may need to switch the tango workspace to one that contains \`.xcodeproj\` / \`.xcworkspace\`.
- \`project.kind === 'error'\`: surface the error verbatim.
- \`project.kind === 'ambiguous'\`: ask the user which candidate to map.
- \`project.kind === 'detected'\`: proceed.

\`Read\` \`tango-memory.md\` first. If a previous session has already mapped the app (look for "Mapped iOS app:" in the memory log), confirm with the user before re-mapping — the cached scan makes re-runs cheap, but the user may have asked just to confirm last session's shape.

### 2. Don't trample existing canvas content

\`get_canvas_state\`. If \`elements.length > 0\`, ask the user before \`set_screen_flow\` (which replaces by default). Phrase it: *"There's existing content on the canvas — replace it with the screen-flow diagram, or place it alongside?"*

If they want to keep what's there: pass \`options.append: true\` and an \`options.origin\` offset so the new diagram doesn't overlap.

### 3. Scan

Call \`scan_ios_app\`. Pass \`includeSummaries: true\` if the user said anything like "describe each screen", "summarize", or "with a one-liner"; otherwise omit it (faster, and the user can ask later).

The scanner detects:

- **SwiftUI** — top-level \`struct X: View\` (nested inner views are skipped).
- **UIKit** — top-level \`class X: ...UIViewController|VC\`.
- **Storyboard** — \`<viewController>\` scenes; \`customClass\` wins as id, falls back to the scene id.
- **Edges** — \`NavigationLink(destination:)\`, \`.navigationDestination\`, \`.sheet\`, \`.fullScreenCover\`, \`pushViewController\`, \`present\`, \`TabView\` children, \`<segue destination=…>\`.
- **Entries** — \`@main\` + \`WindowGroup { Root() }\`, \`AppDelegate.window?.rootViewController = X()\`, \`<viewController isInitialViewController="YES">\`.

If \`scannedFiles + cachedFiles\` is suspiciously small (e.g. 0–2 on what should be a real app), the scanner may have run from the wrong directory or the project may be entirely outside the workspace. Tell the user and stop.

### 4. Sanity-check the graph (before drawing)

Glance at the result before calling \`set_screen_flow\`. **Trim now — re-trimming after the first draw forces a second \`set_screen_flow\` and overwrites the user's view of the bad first draw.**

- **Card-count gut check.** If \`screens.length\` is way out of line with what feels right for the project — 80 cards on what's clearly a small app, or 3 cards on something big — the scanner has likely picked up leaf components as screens (former) or your \`rootDir\` is misaligned (latter). Drop the obvious leaves from the \`screens\` array; \`set_screen_flow\` silently drops edges to types you removed, so you don't have to clean \`edges\` separately.
- **Other false positives.** Drop any types that aren't really screens (a row component picked up as a SwiftUI View, a helper that conforms to View for previewing, etc.).
- **Entry detection.** If \`screens.some(s => s.isEntry)\` is false, the scanner couldn't detect an entry. \`set_screen_flow\` falls back to "no-incoming-edges" nodes as entries — usually fine. Override only if you have evidence (e.g. the user named the entry).
- **Very large apps** (>200 screens): warn the user before drawing — the diagram will be wide.

### 5. One \`set_screen_flow\` call

Hand the graph straight through:

\`\`\`json
{
  "screens": [...],   // from scan_ios_app, possibly trimmed
  "edges":   [...],   // from scan_ios_app
  "options": { "append": false }
}
\`\`\`

Don't dribble the diagram in via multiple \`add_elements\` — \`set_screen_flow\` runs the layered layout in one go and that's how it stays orderly.

### 6. Inspect the result

\`set_screen_flow\` returns a JSON result with \`written\` counts and a \`diagnostics\` object: \`{ danglingEdges: […], layoutOverlaps: […] }\`. If both arrays are empty, the diagram is clean — you're done.

If \`diagnostics.danglingEdges\` is non-empty, you've dropped edges to types that weren't recognized as screens — usually fine (the scanner over-captures and the layout silently drops these), but mention the count to the user. If \`diagnostics.layoutOverlaps\` is non-empty, re-call with \`options.cardWidth: 280\` (more horizontal room) or \`options.cardHeight: 180\` (more vertical room).

If after drawing the card count *still* looks wrong, trim more screens and re-call \`set_screen_flow\` with the same payload minus the leaf components — the second call defaults to replacing the canvas, so the bad first draw is overwritten.

Only call \`screenshot_canvas\` if the user explicitly asked to see the diagram, the diagnostics flagged a layout issue you can't reason about from the JSON, or the graph is unusually large (≥30 screens) and you want to vibe-check the visual before claiming done.

### 7. Tell the user what they got

A one-sentence summary: *"Mapped 14 screens and 22 navigation edges. \`HomeView\` is the entry (highlighted in amber). Push edges are black; sheets blue; covers purple; tab links teal."*

Mention what you couldn't classify — if there are 6 storyboard scenes you couldn't link to Swift code, say so. Partial maps are useful; pretending to be complete is not.

### 8. Record it

\`remember_note({ category: 'context', text: 'Mapped iOS app: N screens, M edges. Entry: <Name>.' })\` — future sessions will see this in \`tango-memory.md\` and won't re-scan unless the user asks.

## Anti-patterns

- Don't \`Glob\` and \`Read\` Swift files yourself — \`scan_ios_app\` is the seam, and re-doing it in-context burns time and tokens. The only Swift you should \`Read\` here is a specific file the user pointed at.
- Don't run \`xcodebuild\` for this — that's \`tango-ios-sim\`'s job. Mapping is read-only and doesn't need a built binary.
- Don't include test targets, preview providers, or design-time \`.swift\` files. The scanner already filters these.
- Don't try to render the *contents* of each screen on the cards — text-only cards are the bar. For one screen at a time with rendered UI, point the user at \`tango-swiftui\` instead.
- Don't ask before scanning — once preconditions are met, just call \`scan_ios_app\`. The scanner is cheap and re-runs are cached.
- Don't \`clear_canvas\` without checking with the user first when the canvas already has content.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

// Externalized reference for `tango-swiftui` — the dense SwiftUI ↔ UINode
// mapping cheat sheet. Loaded by Claude on demand via `Read`, so it doesn't
// burn skill-body tokens on every invocation. Kept as a separate string here
// so unit tests can assert it lands on disk without filesystem fixtures.
const SWIFTUI_MAPPING_REFERENCE_MD = `# SwiftUI ↔ UINode mapping reference

Companion to \`.claude/skills/tango-swiftui/SKILL.md\`. The skill body has the playbook and a 7-row "common cases" table; this file has the full per-view mapping for everything else.

## SwiftUI → UINode

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

## UINode → SwiftUI

Inverse of the above plus container inference (skill body's Write flow §3). Layout-affecting CSS keys in \`style\` (\`position\`, \`top\`, \`left\`, \`width\`, \`height\`, \`transform\`, \`display\`, \`flex*\`, \`grid*\`) are dropped by the renderer, so you'll never see them on read; on write, infer SwiftUI layout from coords, not from any (absent) CSS hints.

Cluster siblings to recover containers:

- Similar \`y\`, rising \`x\` → \`HStack(spacing:)\`. \`spacing\` ≈ mean adjacent gap.
- Similar \`x\`, rising \`y\` → \`VStack(spacing:)\`.
- Overlapping in both axes → \`ZStack\`.
- A leaf with non-trivial offset from container origin → \`.padding(...)\` rather than a wrapping container.

---

This reference is generated by tango and overwritten on each server boot. To customize, fork the parent skill under a different name in \`.claude/skills/\` — tango won't touch other skills.
`;

const CLAUDE_MD_SENTINEL_START = '<!-- tango:start (managed by tango — do not edit) -->';
const CLAUDE_MD_SENTINEL_END = '<!-- tango:end -->';
const CLAUDE_MD_BLOCK = `${CLAUDE_MD_SENTINEL_START}\n@.claude/tango.md\n${CLAUDE_MD_SENTINEL_END}`;

// First match only — second-pass `ensureWorkspace` calls should be idempotent.
// Multiline / dotall: `[\s\S]*?` non-greedy across lines.
const SENTINEL_RE = /<!-- tango:start[\s\S]*?<!-- tango:end -->/;

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

// Writes a skill's `SKILL.md` plus an arbitrary set of sibling reference
// files under `_reference/<name>.md`. The reference files are loaded by
// Claude on demand via the `Read` tool — keeps the always-loaded SKILL.md
// small while preserving the dense per-domain detail (mapping cheat sheets,
// element JSON shapes, …). All paths are inside the workspace.
type SkillReference = { fileName: string; body: string };
async function writeSkillBundle(
  workspace: string,
  name: string,
  body: string,
  references: SkillReference[] = [],
): Promise<void> {
  const skillDir = path.join(workspace, '.claude', 'skills', name);
  await fs.mkdir(skillDir, { recursive: true });
  await writeIfChanged(path.join(skillDir, 'SKILL.md'), body);
  if (references.length === 0) return;
  const refDir = path.join(skillDir, '_reference');
  await fs.mkdir(refDir, { recursive: true });
  for (const ref of references) {
    await writeIfChanged(path.join(refDir, ref.fileName), ref.body);
  }
}

export type EnsureError = { file: string; reason: string };
export type EnsureResult =
  | { ok: true }
  | { ok: false; errors: EnsureError[] };

// Set up our managed bits in `workspace`. Returns soft errors for each
// file we refused to write because it was malformed; we still write the
// pieces we own (.claude/tango.md, design-scratch/) and the CLAUDE.md
// sentinel block, so the workspace remains usable.
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
  await fs.mkdir(path.join(workspace, 'design-scratch'), { recursive: true });

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

  // Each skill bundle: SKILL.md (always overwritten, wholly tango-managed)
  // plus an optional `_reference/` folder for dense material the model loads
  // on demand via `Read`. New references go in their own file alongside
  // SKILL.md so the always-loaded body stays small.
  await writeSkillBundle(workspace, 'tango-ui-sketch', UI_SKETCH_SKILL_MD);
  await writeSkillBundle(workspace, 'tango-ui-mock', UI_MOCK_SKILL_MD);
  await writeSkillBundle(workspace, 'tango-swiftui', SWIFTUI_SKILL_MD, [
    { fileName: 'mappings.md', body: SWIFTUI_MAPPING_REFERENCE_MD },
  ]);
  await writeSkillBundle(workspace, 'tango-ios-sim', TANGO_IOS_SIM_SKILL_MD);
  await writeSkillBundle(workspace, 'tango-ios-map', TANGO_IOS_MAP_SKILL_MD);

  // Best-effort cleanup of the previous skill name in workspaces that were
  // ensured before the rename. It was wholly tango-managed, so it's safe to
  // remove. Ignore any error (missing dir, permissions, user-modified) — the
  // new skill is what we care about.
  await fs.rm(
    path.join(workspace, '.claude', 'skills', 'tango-codebase-sketch'),
    { recursive: true, force: true },
  ).catch(() => {});

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
