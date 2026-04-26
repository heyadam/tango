import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ensureMemory } from './memory';

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
};

const SLOT_KEY = '__tangoWorkspaceSlot__';

function getSlot(): WorkspaceSlot {
  const g = globalThis as typeof globalThis & {
    [SLOT_KEY]?: WorkspaceSlot;
  };
  if (!g[SLOT_KEY]) {
    g[SLOT_KEY] = { currentWorkspace: null, workspaceSource: 'unset' };
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
const TANGO_MD = `# Designer canvas (tango)

You're running inside the **tango** workspace. The user is viewing an Excalidraw canvas in the left pane of their browser; this terminal is in the right pane. The \`tango-canvas\` MCP server lets you read and modify that canvas:

- \`get_canvas_state\` — read the current scene (elements + appState; embedded image bytes elided)
- \`set_canvas_state\` — replace the entire scene
- \`add_elements\` — append elements without disturbing existing ones
- \`clear_canvas\` — empty the scene
- \`screenshot_canvas\` — see the rendered canvas as an image (call this before proposing wireframes, critiques, or anything that depends on what the user has drawn — \`get_canvas_state\` strips embedded image bytes, this gives you the actual pixels)

Reach for these whenever the user asks for visual work — wireframes, diagrams, sketches, layout proposals. Prefer \`add_elements\` when annotating or extending; \`set_canvas_state\` for a full redesign. Element shape matches Excalidraw's \`serializeAsJSON\` output — call \`get_canvas_state\` first if you need to see the shape.

The same MCP server also exposes **UI mock tools** for tango's "UI" mode — a higher-fidelity surface where the user sees real shadcn/Tailwind components instead of an Excalidraw wireframe, and can drag/resize/text-edit them directly:

- \`get_ui_mock\` — read the current shadcn-based UI mock spec (call this first; user tweaks live here)
- \`set_ui_mock\` — replace the whole spec (one or more screens of absolutely-positioned nodes)
- \`add_ui_screen\` — append a screen to an existing flow without touching the others
- \`clear_ui_mock\` — empty the spec

For UI sketching ("sketch my UI", "wireframe this screen", "draw a layout for X"), follow the **\`tango-ui-sketch\`** skill at \`.claude/skills/tango-ui-sketch/SKILL.md\` — it turns a UI into an Excalidraw wireframe (structure, no pixels).

For higher-fidelity UI prototyping ("mock my UI in shadcn", "show me what the X screen would look like", "build a UI mock of Y", "prototype this flow"), follow the **\`tango-ui-mock\`** skill at \`.claude/skills/tango-ui-mock/SKILL.md\` instead — it transcribes a real production UI into the shadcn-based mock surface, where the user can drag, resize, and edit text, and then ship the tweaks back as a reference for the production codebase. Use \`tango-ui-mock\` when the user wants to *visualize and tweak* a UI; \`tango-ui-sketch\` when they want a wireframe.

Edits via these tools appear on the user's canvas immediately. The user can \`Cmd+Z\` your changes, and their edits flow back so \`get_canvas_state\` always reflects what's on their screen right now.

For visual context, prefer \`screenshot_canvas\` — it's the live channel. The user may also drop a PNG into \`design-scratch/\` and ping you with a \`# review design at design-scratch/...png\` comment line; that's the deliberate-handoff channel — read the file when they point you at it.

## Workspace memory

A live memory file lives at \`./tango-memory.md\` — read it now for prior context (snapshots taken, agent runs, recorded design decisions). When the user states a design decision, constraint, or context worth keeping for future sessions, call the \`remember_note\` MCP tool with the appropriate \`category\` (\`'decision'\`, \`'context'\`, or \`'todo'\`). Don't edit the Summary or Recent sections of \`tango-memory.md\` directly — those are managed by tango. Your own working notes go in the \`Notes (yours)\` block at the bottom, which tango never touches. Note: snapshot captions and recorded notes are summarized via the same OpenAI key as the controller agent.

---

This file is generated by tango and overwritten on each server boot. Don't hand-edit — put project-specific instructions in your own CLAUDE.md (the part outside the \`tango:start\` … \`tango:end\` block is yours).
`;

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

### 7. Verify, then iterate
Call \`screenshot_canvas\` immediately after writing. Look for:
- Boxes overlapping, clipped by the frame, or outside the frame → recompute coords, \`set_canvas_state\` to fix
- Labels clipped or running outside their box → grow the box or shrink the label
- Empty regions reading as "broken" rather than "intentionally blank" → add a placeholder line or a region label
- Multiple screens drifting out of alignment → snap to the gutter math

Don't tell the user "done" until the screenshot looks right. Iterate.

### 8. Record it
Call \`remember_note({ category: 'context', text: 'Sketched UI: <one-line shape, e.g. "Mobile to-do screen — header, list, FAB">' })\`. Future sessions will see this in \`tango-memory.md\`.

## Anti-patterns
- Don't chase pixel-perfection or visual fidelity. Wireframes are about structure.
- Don't add fills, brand colors, or icons. Stroke and text only.
- Don't draw what the user didn't ask for. "Sketch the login screen" means one screen, not three.
- Don't \`clear_canvas\` without asking.
- Don't skip the \`screenshot_canvas\` verify step. Element JSON looks fine on paper and lays out badly in practice.
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

\`get_ui_mock\`, \`set_ui_mock\`, \`add_ui_screen\`, \`clear_ui_mock\` (from the \`tango-canvas\` MCP server, same as the canvas tools). The spec shape:

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

| Form factor | Frame size      |
|-------------|-----------------|
| Mobile      | 360 × 720       |
| Tablet      | 768 × 1024      |
| Desktop     | 1280 × 800      |

Multi-screen flows: separate \`UIScreen\` objects, one per screen. The panel tiles them left-to-right with a gutter — your coords stay screen-local.

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

### 5. Style with \`className\`, not coordinates

Put visual styling on \`className\` (Tailwind for color, padding, typography, borders, shadows). **Layout-affecting Tailwind classes are dropped** by the renderer — coords win — so don't use \`flex\`, \`grid\`, \`w-full\`, \`h-full\` etc. Examples that work:

- Card surface: \`bg-card text-card-foreground border rounded-lg shadow-sm\`
- Muted body text: \`text-muted-foreground\`
- Heading prominence: handled by \`type: 'heading'\` + \`props.level\`
- Subtle dividing line inside a region: \`bg-border\` on a thin \`div\`

### 6. Don't trample existing work

Always \`get_ui_mock\` first.

- Empty? \`set_ui_mock\` with your full draft.
- Has screens you want to keep? Use \`add_ui_screen\` to append.
- The user explicitly asked to start over? \`clear_ui_mock\` then \`set_ui_mock\`. Confirm in chat first if it's not obvious from the prompt.

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
- Don't \`clear_ui_mock\` without asking.
- Don't invent a \`type\` outside the union. The validator will reject; the user sees an error.
- Don't import \`@excalidraw/excalidraw\` or use the canvas tools here — \`tango-ui-sketch\` is the wireframe path.
- Don't skip the verify round-trip on \`get_ui_mock\`. Spec JSON looks fine on paper and overflows the frame in practice.

---

This skill is generated by tango and overwritten on each server boot. To customize, fork it under a different name in \`.claude/skills/\` — tango won't touch other skills.
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
  await fs.mkdir(
    path.join(workspace, '.claude', 'skills', 'tango-ui-sketch'),
    { recursive: true },
  );
  await fs.mkdir(
    path.join(workspace, '.claude', 'skills', 'tango-ui-mock'),
    { recursive: true },
  );

  // .claude/tango.md — wholly ours, always overwrite.
  await writeIfChanged(path.join(workspace, '.claude', 'tango.md'), TANGO_MD);

  // .claude/skills/tango-ui-sketch/SKILL.md — wholly ours, always overwrite.
  // Auto-discovered by Claude Code; gives terminal-Claude a tuned playbook for
  // turning a UI (existing or proposed) into an Excalidraw wireframe.
  await writeIfChanged(
    path.join(workspace, '.claude', 'skills', 'tango-ui-sketch', 'SKILL.md'),
    UI_SKETCH_SKILL_MD,
  );

  // .claude/skills/tango-ui-mock/SKILL.md — wholly ours, always overwrite.
  // Sibling skill that drives terminal-Claude through tango's high-fidelity
  // "UI" mode (shadcn/Tailwind mock with drag/resize/text-edit).
  await writeIfChanged(
    path.join(workspace, '.claude', 'skills', 'tango-ui-mock', 'SKILL.md'),
    UI_MOCK_SKILL_MD,
  );

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
