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

For codebase-architecture diagrams ("draw my codebase", "diagram this repo", "sketch the architecture"), follow the **\`tango-codebase-sketch\`** skill at \`.claude/skills/tango-codebase-sketch/SKILL.md\` — it has the survey → model → layout playbook tuned for Excalidraw.

Edits via these tools appear on the user's canvas immediately. The user can \`Cmd+Z\` your changes, and their edits flow back so \`get_canvas_state\` always reflects what's on their screen right now.

For visual context, prefer \`screenshot_canvas\` — it's the live channel. The user may also drop a PNG into \`design-scratch/\` and ping you with a \`# review design at design-scratch/...png\` comment line; that's the deliberate-handoff channel — read the file when they point you at it.

## Workspace memory

A live memory file lives at \`./tango-memory.md\` — read it now for prior context (snapshots taken, agent runs, recorded design decisions). When the user states a design decision, constraint, or context worth keeping for future sessions, call the \`remember_note\` MCP tool with the appropriate \`category\` (\`'decision'\`, \`'context'\`, or \`'todo'\`). Don't edit the Summary or Recent sections of \`tango-memory.md\` directly — those are managed by tango. Your own working notes go in the \`Notes (yours)\` block at the bottom, which tango never touches. Note: snapshot captions and recorded notes are summarized via the same OpenAI key as the controller agent.

---

This file is generated by tango and overwritten on each server boot. Don't hand-edit — put project-specific instructions in your own CLAUDE.md (the part outside the \`tango:start\` … \`tango:end\` block is yours).
`;

// Skill body for `${workspace}/.claude/skills/tango-codebase-sketch/SKILL.md`.
// Auto-discovered by Claude Code from `.claude/skills/<name>/SKILL.md` and
// invocable both as a slash command (`/tango-codebase-sketch`) and via the
// model's auto-invocation against the `description` field. Wholly tango-
// managed, same overwrite policy as `.claude/tango.md`.
const CODEBASE_SKETCH_SKILL_MD = `---
name: tango-codebase-sketch
description: Survey the project and draw a high-level architecture sketch on the tango Excalidraw canvas. Use when the user asks to diagram, visualize, sketch, map, or translate the codebase into a drawing.
---

# Codebase → sketch

You're inside a tango workspace, so the user is staring at an Excalidraw canvas in their left pane. Your job: turn this codebase into a clear, labeled, **5–12 box** architecture sketch on that canvas. Not a class diagram. Not every file. The shape of the system.

Use the \`tango-canvas\` MCP tools (already loaded): \`get_canvas_state\`, \`add_elements\`, \`set_canvas_state\`, \`clear_canvas\`, \`screenshot_canvas\`.

## Playbook

### 1. Survey (be quick)
- Read \`README*\`, then the manifest (\`package.json\`, \`pyproject.toml\`, \`Cargo.toml\`, \`go.mod\`, etc.) for name + entry points + deps.
- Glob the top-level source dir (\`src/\`, \`app/\`, \`lib/\`, or whatever the manifest points at). Note the directory structure, not file contents.
- \`Read\` 3–5 entry points only — CLI main, server bootstrap, primary route file. Stop the moment you can describe the system in one paragraph.
- If the repo is a Next.js / React / Rails / Django / Express app, you already know the broad shape — go faster.

### 2. Build a small model
Group files into **5–12 nodes** (not 50). Categorize each as one of:
- **Entry point** — what the user/runtime hits first (CLI, HTTP server, main fn)
- **Internal module** — owned domain code (\`auth/\`, \`payments/\`, \`canvas/\`)
- **External service** — third-party API, database, queue, SDK (Stripe, Postgres, Redis, OpenAI)
- **Data store** — DB, file system area, cache

Pick the 3–8 most important edges (imports, calls, "writes to", "reads from"). Skip every edge — the goal is legibility, not completeness.

### 3. Decide layout
- **Left-to-right pipeline** if there's clear data flow (input → process → output)
- **Top-to-bottom layered** if there's clear stratification (UI / API / domain / data)
- **Hub-and-spoke** if there's one entry point fanning out to modules

Default grid: boxes \`280 × 120\`, pitch \`320 × 180\`. Origin around \`(100, 100)\`. Adjust if the canvas is wider/narrower (call \`get_canvas_state\` to peek at \`appState.width/height\` first).

### 4. Don't trample the canvas
\`get_canvas_state\` first. If it has existing elements:
- **Default**: use \`add_elements\` and place the new diagram in empty space below/right of existing content.
- Ask the user before \`clear_canvas\` or \`set_canvas_state\` — those wipe their work. Phrase it: *"There's already content on the canvas — clear it, or place the diagram alongside?"*

If the canvas is empty, go straight to \`add_elements\`.

### 5. Push elements
Excalidraw element shape matches \`serializeAsJSON\`. Permissive — extra fields are fine, missing fields default. **If unsure, call \`get_canvas_state\` first and copy the field set you see.** Two minimal templates:

**Labeled rectangle** (one node):
\`\`\`json
[
  { "type": "rectangle", "id": "node-auth", "x": 100, "y": 100, "width": 280, "height": 120,
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100, "angle": 0,
    "roundness": { "type": 3 } },
  { "type": "text", "id": "label-auth", "x": 120, "y": 140, "width": 240, "height": 24,
    "text": "auth/", "fontSize": 20, "fontFamily": 1, "textAlign": "left",
    "verticalAlign": "top", "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
    "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 1,
    "opacity": 100, "angle": 0 }
]
\`\`\`

**Arrow** (one edge — points are relative to (x,y)):
\`\`\`json
[
  { "type": "arrow", "id": "edge-1", "x": 380, "y": 160, "width": 320, "height": 0,
    "points": [[0, 0], [320, 0]],
    "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
    "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100, "angle": 0,
    "endArrowhead": "arrow", "startArrowhead": null }
]
\`\`\`

Style rules:
- One stroke color throughout (\`#1e1e1e\`). No decorative colors.
- Label every box. No floating rectangles.
- For "external service" nodes, set \`strokeStyle: "dashed"\` so they read as boundaries.
- Place text inside the rectangle's bounding box (text \`x/y\` ≈ rect \`x+20, y+20\`).
- Arrows: keep them axis-aligned (horizontal or vertical). Diagonal arrows in a grid look noisy.

Make the \`add_elements\` call(s). One call with all elements is cheaper than many.

### 6. Verify
Call \`screenshot_canvas\` immediately after writing. Look for:
- Boxes overlapping or off-canvas → recompute coords, \`set_canvas_state\` to fix
- Labels clipped or unreadable → grow the box or shrink the label
- Arrows pointing nowhere → check \`x/y\` + \`points\` math

Don't tell the user "done" until the screenshot looks right. Iterate.

### 7. Record it
Call \`remember_note({ category: 'context', text: 'Sketched codebase architecture: <one-line shape, e.g. "Next.js app — 7 modules, hub-and-spoke around server.ts"> ' })\`. Future sessions will see this in \`tango-memory.md\`.

## Anti-patterns
- Don't draw every file. 5–12 nodes, not 50.
- Don't invent edges. Only connect modules where you've actually seen an import or call.
- Don't write a class diagram. The user wants the *shape* of their system, not the inheritance graph.
- Don't \`clear_canvas\` without asking.
- Don't skip the \`screenshot_canvas\` verify step. Element JSON looks fine on paper and lays out badly in practice.

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
    path.join(workspace, '.claude', 'skills', 'tango-codebase-sketch'),
    { recursive: true },
  );

  // .claude/tango.md — wholly ours, always overwrite.
  await writeIfChanged(path.join(workspace, '.claude', 'tango.md'), TANGO_MD);

  // .claude/skills/tango-codebase-sketch/SKILL.md — wholly ours, always overwrite.
  // Auto-discovered by Claude Code; gives terminal-Claude a tuned playbook for
  // turning the workspace's codebase into an Excalidraw architecture diagram.
  await writeIfChanged(
    path.join(workspace, '.claude', 'skills', 'tango-codebase-sketch', 'SKILL.md'),
    CODEBASE_SKETCH_SKILL_MD,
  );

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
