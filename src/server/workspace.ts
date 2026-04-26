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

For UI sketching ("sketch my UI", "wireframe this screen", "draw a layout for X", "mock up Y"), follow the **\`tango-ui-sketch\`** skill at \`.claude/skills/tango-ui-sketch/SKILL.md\` — it has a tuned playbook for turning a UI (existing or proposed) into a clean Excalidraw wireframe. Reach for it on any "sketch / wireframe / mock up / lay out / design" prompt that's about a UI, screen, page, or interface — not just architecture diagrams.

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

  // .claude/tango.md — wholly ours, always overwrite.
  await writeIfChanged(path.join(workspace, '.claude', 'tango.md'), TANGO_MD);

  // .claude/skills/tango-ui-sketch/SKILL.md — wholly ours, always overwrite.
  // Auto-discovered by Claude Code; gives terminal-Claude a tuned playbook for
  // turning a UI (existing or proposed) into an Excalidraw wireframe.
  await writeIfChanged(
    path.join(workspace, '.claude', 'skills', 'tango-ui-sketch', 'SKILL.md'),
    UI_SKETCH_SKILL_MD,
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
