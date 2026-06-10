// Fast import: SwiftUI sources → design screens, via a purpose-built direct
// Anthropic API loop instead of the general terminal agent. The model gets a
// frozen system prompt (the SwiftUI→UINode mapping rules — prompt-cached
// across runs), a read-only `read_swift_file` tool, and an `emit_screen` tool
// whose input is validated against the shared zod schema before it touches
// the live spec. No LLM on the export side; this is the agent-mediated half
// of the hybrid translation rule, just without the CLI agent in the loop.
//
// Runs in the route-handler module graph (kicked from /api/ui/import), so all
// spec reads/writes go through the cross-graph hook registry — never import
// uiMockBridge from here (its module-load registerHook calls would clobber
// the server graph's registrations with a copy that has an empty cache).

import { promises as fs } from 'node:fs';
import path from 'node:path';
import Anthropic from '@anthropic-ai/sdk';
import * as z from 'zod/v4';
import { uiScreenSchema } from '@/lib/uiMockSchema';
import { hashSource } from './sourceHash';
import type { UIScreen, UISpec } from '@/lib/uiMockProtocol';
import { getHook } from './serverHooks';
import { getWorkspaceOrNull } from './workspace';
import { importModel } from './config';

export type UiImportState =
  | { phase: 'idle' }
  | {
      phase: 'running';
      startedAt: number;
      filesFound: number;
      filesRead: number;
      screensImported: number;
    }
  | {
      phase: 'done';
      ok: true;
      screensImported: number;
      filesRead: number;
      durationMs: number;
      summary: string;
      finishedAt: number;
    }
  | { phase: 'error'; message: string; finishedAt: number };

type UiImportSlot = { state: UiImportState };

const SLOT_KEY = '__tangoUiImportSlot__';

function getSlot(): UiImportSlot {
  const g = globalThis as typeof globalThis & { [SLOT_KEY]?: UiImportSlot };
  if (!g[SLOT_KEY]) g[SLOT_KEY] = { state: { phase: 'idle' } };
  return g[SLOT_KEY];
}

export function getUiImportState(): UiImportState {
  return getSlot().state;
}

export function isUiImportActive(): boolean {
  return getSlot().state.phase === 'running';
}

// ── Swift source discovery ──────────────────────────────────────────────────

export type SwiftFileInfo = {
  relPath: string;
  bytes: number;
  // Lives under TangoGenerated/ — tango's own earlier export of a canvas
  // design. Not a user source, but the best available record of the design
  // when the canvas no longer has those screens (cleared, fresh machine, …).
  generated: boolean;
};

// Directories that never contain screen sources. Matched against any path
// segment, so nested `Foo/Pods/...` is skipped too. TangoGenerated/ is NOT
// here — it's surfaced separately as round-trippable design exports.
const SKIP_DIRS = new Set([
  'Pods',
  'DerivedData',
  'build',
  '.build',
  '.swiftpm',
  '.tango',
  '.git',
  'node_modules',
  'Preview Content',
]);

const GENERATED_DIR = 'TangoGenerated';
// Codegen plumbing, not screens (see specToSwiftUI): the shared support file
// and the root TabView index.
const GENERATED_NON_SCREEN_FILES = new Set([
  'TangoSupport.swift',
  'TangoGeneratedIndex.swift',
  'TangoGeneratedRootView.swift',
]);

// Pure, tested: is this a TangoGenerated *screen* file (a re-importable
// design export, as opposed to codegen plumbing or a user source)?
export function isGeneratedScreenPath(relPath: string): boolean {
  const segments = relPath.split(path.sep);
  if (!segments.includes(GENERATED_DIR)) return false;
  const base = segments[segments.length - 1];
  return base.endsWith('.swift') && !GENERATED_NON_SCREEN_FILES.has(base);
}

// Pure, tested: should this workspace-relative path be excluded from the
// import file list? (User sources only — TangoGenerated paths are routed
// through isGeneratedScreenPath instead.)
export function shouldSkipSwiftPath(relPath: string): boolean {
  const segments = relPath.split(path.sep);
  if (segments.some((s) => SKIP_DIRS.has(s))) return true;
  const base = segments[segments.length - 1];
  if (/Tests?\.swift$/.test(base)) return true;
  if (segments.some((s) => /Tests?$/.test(s) && !s.endsWith('.swift'))) {
    return true;
  }
  return false;
}

const MAX_FILES_LISTED = 200;
const MAX_SCAN_DEPTH = 8;

export async function findSwiftFiles(
  workspace: string,
): Promise<SwiftFileInfo[]> {
  const out: SwiftFileInfo[] = [];
  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > MAX_SCAN_DEPTH || out.length >= MAX_FILES_LISTED) return;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (out.length >= MAX_FILES_LISTED) return;
      const abs = path.join(dir, entry.name);
      const rel = path.relative(workspace, abs);
      if (entry.isDirectory()) {
        if (!SKIP_DIRS.has(entry.name)) await walk(abs, depth + 1);
        continue;
      }
      if (!entry.name.endsWith('.swift')) continue;
      const inGenerated = rel.split(path.sep).includes(GENERATED_DIR);
      if (inGenerated) {
        if (!isGeneratedScreenPath(rel)) continue;
      } else if (shouldSkipSwiftPath(rel)) {
        continue;
      }
      try {
        const stat = await fs.stat(abs);
        out.push({ relPath: rel, bytes: stat.size, generated: inGenerated });
      } catch {
        // raced deletion — skip
      }
    }
  }
  await walk(workspace, 0);
  out.sort((a, b) => a.relPath.localeCompare(b.relPath));
  return out;
}

// ── Spec application ────────────────────────────────────────────────────────

// Pure, tested: replace the screen with the same id, or append. Imported
// screens never disturb other screens (the user's existing work survives).
// A replacement that omits sourceFile keeps the prior screen's provenance —
// sourceHash travels with it (re-emits and TangoGenerated round-trips don't
// re-state the user source).
export function applyEmittedScreen(current: UISpec, screen: UIScreen): UISpec {
  const idx = current.screens.findIndex((s) => s.id === screen.id);
  if (idx === -1) {
    return { screens: [...current.screens, screen] };
  }
  const screens = current.screens.slice();
  const prior = screens[idx];
  if (screen.sourceFile === undefined && prior.sourceFile !== undefined) {
    const carried: UIScreen = { ...screen, sourceFile: prior.sourceFile };
    if (prior.sourceHash !== undefined) carried.sourceHash = prior.sourceHash;
    screens[idx] = carried;
  } else {
    screens[idx] = screen;
  }
  return { screens };
}

// Pure, tested: reject screens whose node ids collide (within the screen) —
// the canvas addresses nodes by id, so a duplicate would make later
// `update_ui_node` calls ambiguous.
export function findDuplicateNodeId(screen: UIScreen): string | null {
  const seen = new Set<string>();
  for (const node of screen.nodes) {
    if (seen.has(node.id)) return node.id;
    seen.add(node.id);
  }
  return null;
}

// Pure, tested: deterministic post-emit lint. The model can't see the render,
// so feed obvious layout defects back in the emit_screen tool result and let
// it re-emit a corrected screen in the same run. Warnings, not errors — the
// model may have a reason (e.g. intentionally tall wrapping text).
const TEXTY_TYPES = new Set(['text', 'heading', 'Button', 'Badge']);

export function lintScreen(screen: UIScreen): string[] {
  const warnings: string[] = [];
  for (const node of screen.nodes) {
    if (
      node.x < 0 ||
      node.y < 0 ||
      node.x + node.width > screen.frame.w ||
      node.y + node.height > screen.frame.h
    ) {
      warnings.push(
        `node "${node.id}" extends outside the ${screen.frame.w}×${screen.frame.h} frame (x ${node.x}, y ${node.y}, w ${node.width}, h ${node.height})`,
      );
    }
    const text = node.text?.trim();
    if (text && TEXTY_TYPES.has(node.type)) {
      // ~8px/char body, ~14px/char heading (SF Pro at default sizes), plus
      // padding. Only meaningful for single/double-line nodes — tall nodes
      // are presumed to wrap.
      const perChar = node.type === 'heading' ? 14 : 8;
      const needed = Math.min(
        text.length * perChar + 16,
        Math.round(screen.frame.w * 0.95),
      );
      if (node.height <= 48 && node.width < needed) {
        const preview = text.length > 40 ? `${text.slice(0, 40)}…` : text;
        warnings.push(
          `node "${node.id}" is ${node.width}px wide but its text "${preview}" needs ~${needed}px — the canvas clips overflow; widen the node (or shorten the text)`,
        );
      }
    }
  }
  return warnings;
}

// ── Prompt + tools ──────────────────────────────────────────────────────────

// Frozen system prompt — the SwiftUI→UINode mapping rules, condensed from the
// tango-swiftui / tango-ui-import skills. Keep byte-stable (no timestamps, no
// workspace paths): it carries a cache breakpoint so repeat imports read the
// whole instruction set from the prompt cache.
export const UI_IMPORT_SYSTEM_PROMPT = `You are tango's SwiftUI import engine. Translate an iOS workspace's screen-level SwiftUI views into design screens on tango's canvas. Read sources with \`read_swift_file\`; emit one screen per screen-level View with \`emit_screen\`. Import is read-only on the Swift side — you have no file-writing tools and must not propose source edits.

## What counts as a screen

A screen-level View is a top-level \`struct X: View\` representing a full screen: the \`@main\` App's root, NavigationStack/TabView destinations, sheet contents. Leaf components (a row, a button style) are NOT screens — they render as nodes inside their parent screen. Skip #Preview bodies and PreviewProviders.

## Coordinate projection

Every leaf view becomes one UINode with absolute pixel coords inside the screen frame. Walk the body recursively; containers (VStack, HStack, ZStack, Group, ScrollView, Form, Section, NavigationStack, List) emit no nodes — they only position their children:

- VStack(spacing: s): child y = previous.y + previous.height + s; x aligned to the container.
- HStack(spacing: s): child x = previous.x + previous.width + s; y aligned to the container.
- ZStack(alignment:): children overlap at the same origin, offset by alignment.
- .frame(width:height:): use those pixel values. One dimension given → default the other.
- Bare leaves: Button 160×40, TextField full-width × 40, Image 96×96, Icon 24×24, Separator full-width × 1.
- Spacer(): leave a gap in the next sibling's coords; no node.
- .padding(p): inflate child coords by p on the relevant axes.
- List/ForEach rows: flatten to a div per row with child nodes inside.

**SwiftUI centers by default — honor it.** A body whose outermost view is a single VStack/HStack/Text (no Spacer pushing it, no explicit alignment/offset) renders CENTERED in the screen on both axes: compute the stack's total width/height first, then place it so its center sits at (frame.w/2, frame.h/2). To center any single node horizontally: x = (frame.w − width) / 2. Do not leave default-centered content hugging an edge.

**Text sizing — round UP, the canvas clips overflow.** Estimate ~8px per character for body text and ~14px per character for headings (plus ~16px slack), and at least 24px height per line. A 13-character body string needs a ~120px-wide node, not 60px. When unsure, make text nodes wider — extra width is invisible, clipped text is a defect.

## Frame selection

Default 390×844 (iPhone). Use 820×1180 when the source is iPad-only (NavigationSplitView, .regular size-class checks). Keep nodes inside the frame.

## Node mapping

| SwiftUI | UINode type | Notes |
|---|---|---|
| Text | text | Promote to heading + props.level 1/2/3 for .largeTitle/.title/.title2 |
| Button | Button | props.variant: default / secondary (.bordered) / outline / ghost (.plain) / destructive / link; text = label |
| TextField / SecureField | Input | props.placeholder = label string |
| TextEditor | Textarea | |
| Divider | Separator | |
| Image(systemName:) | Icon | props.iconName = closest lucide-react name (gear→Settings, magnifyingglass→Search, chevron.right→ChevronRight, plus→Plus, xmark→X, trash→Trash2, bell→Bell, house→Home, person→User) |
| Image / AsyncImage | Image | props.src only for real URLs |
| Capsule with text overlay | Badge | |
| Rectangle / RoundedRectangle | rect | fill → bg-* or style.backgroundColor; .stroke/.strokeBorder → border-* + border-N; cornerRadius → rounded-* |
| Circle / Ellipse | ellipse | same fill/stroke channels; bare Capsule (no text) → rect + rounded-full |
| Straight 2-point Path (move + addLine) | line (or arrow if it has arrowhead strokes) | props.end from segment direction (n/ne/e/se/s/sw/w/nw); stroke width → border-N, dash → border-dashed |
| Toggle/Picker/Slider/Stepper/DatePicker/ProgressView | Button placeholder | text = "<ViewName>: <label>" |
| Heavier custom drawing (multi-segment Path, Canvas, GeometryReader math) | div placeholder | text = a short label naming what it approximates |

## Styling

Theme-aligned colors go in \`className\` using semantic tokens only (text-foreground, text-muted-foreground, bg-card, bg-muted, bg-accent, border-border). Off-theme colors (exact hex, gradients, shadows) go in the \`style\` object (e.g. {"color":"#0E7C66"}) — never as arbitrary-value Tailwind classes. Fonts: .headline → "text-lg font-semibold", .caption → "text-xs text-muted-foreground".

## TangoGenerated round-trip

Files under TangoGenerated/ are tango's own previous exports of canvas designs ("tango:generated" header). When the canvas no longer has those screens, re-import them at FULL fidelity — and when the app's @main entry renders TangoGeneratedRootView, they are the app's actual UI and importing them is the priority:

- One screen per Tango<Name>Screen file. The header comment \`tango:generated v=1 screen=<id>\` carries the original screen id — reuse it verbatim. The doc comment \`/// <Title> — WxH\` carries the screen title and frame size.
- Coordinates are LITERAL, not inferred: \`.frame(width: W, height: H)\` + \`.offset(x: X, y: Y)\` map directly to node width/height/x/y. Copy the numbers exactly; do not re-derive layout.
- \`Color(tangoR: R, g: G, b: B, a: A)\` is an exact RGB color — convert to hex in the node's \`style\` (e.g. {"color":"#0A1235"}, {"background":"#F5EEE0"}).
- Reverse the node mapping table: Text with a Capsule fill/overlay → Badge; RoundedRectangle cards (with child content) → div; standalone Rectangle/RoundedRectangle → rect and Ellipse() → ellipse; a Path stroke of one straight segment → line (with an arrowhead V-path → arrow, props.end from direction); the polygon Paths emitted for triangle/star nodes → triangle / star (props.points = outer-point count); Image(systemName:) → Icon (map the SF Symbol back to the closest lucide name); \`.font(.system(size:weight:))\` ≥ 22 with bold/serif → heading.
- Ignore container wrappers (\`ZStack(alignment: .topLeading)\`, \`Group {}\`) — they exist only for SwiftUI's ViewBuilder limits.
- When re-importing a TangoGenerated screen, omit \`source_file\` unless you know the original user source — the canvas keeps the screen's prior provenance when it is omitted.

## Procedure

1. From the provided file lists, pick the likely screen sources (App roots, *View/*Screen files, TangoGenerated screen files). Read the @main App entry early — screens reachable from it are what the app actually shows, and they must be imported. Read several files per turn — request multiple read_swift_file calls in one response.
2. Emit each screen as soon as it's translated; don't batch them at the end. Screen id and title = the View's type name (e.g. "OnboardingView"). Prefix node ids with the screen id (e.g. "onboardingview-title") so ids stay unique across the canvas. Always pass \`source_file\` for user sources — the workspace-relative path of the file you translated the screen from, copied from the file list; omit it for TangoGenerated files (see the round-trip rules).
3. If emit_screen returns a validation error, fix the screen and re-emit it. If it returns LAYOUT WARNINGS (clipped text, out-of-frame nodes), treat them as defects: correct the coordinates and re-emit the screen with the same id before moving on.
4. Don't re-read files you've seen; don't read files that are clearly not screens (models, extensions, networking).
5. When every screen is emitted, reply with a one-paragraph summary naming the imported screens. Do not ask follow-up questions — finish the import autonomously.`;

const READ_FILE_CHAR_CAP = 100_000;

function buildTools(): Anthropic.Tool[] {
  return [
    {
      name: 'read_swift_file',
      description:
        'Read one Swift source file from the workspace. `path` must be a workspace-relative path from the provided file list. Returns the full source (truncated past 100KB).',
      input_schema: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Workspace-relative path from the file list',
          },
        },
        required: ['path'],
      },
    },
    {
      name: 'emit_screen',
      description:
        'Add one translated screen to the design canvas. Validated against the canvas schema; replaces an existing screen with the same id, otherwise appends. Emit each screen as soon as it is translated.',
      input_schema: {
        type: 'object',
        properties: {
          screen: z.toJSONSchema(uiScreenSchema) as Record<string, unknown>,
          source_file: {
            type: 'string',
            description:
              'Workspace-relative path of the Swift file this screen was translated from — copy it from the provided file list.',
          },
        },
        required: ['screen'],
      } as Anthropic.Tool['input_schema'],
    },
  ];
}

function buildKickoffMessage(
  files: SwiftFileInfo[],
  existing: UISpec,
): string {
  const userFiles = files.filter((f) => !f.generated);
  const generatedFiles = files.filter((f) => f.generated);
  const listOf = (fs_: SwiftFileInfo[]) =>
    fs_.map((f) => `- ${f.relPath} (${f.bytes} bytes)`).join('\n');
  const existingNote =
    existing.screens.length === 0
      ? 'The canvas is currently empty.'
      : `The canvas already has ${existing.screens.length} screen(s): ${existing.screens
          .map((s) => s.id)
          .join(', ')}. Emitting a screen with one of these ids replaces it; other ids append alongside.`;
  const parts = [
    'Import this workspace\'s SwiftUI screens onto the design canvas.',
    '',
    `User Swift sources (${userFiles.length}):`,
    listOf(userFiles),
  ];
  if (generatedFiles.length > 0) {
    parts.push(
      '',
      `Previously exported design screens in ${GENERATED_DIR}/ (${generatedFiles.length}) — tango's own earlier exports; if the app's entry point renders TangoGeneratedRootView, these ARE the app's current UI. Re-import any whose screens are missing from the canvas (see the TangoGenerated round-trip rules):`,
      listOf(generatedFiles),
    );
  }
  parts.push('', existingNote);
  return parts.join('\n');
}

// Validate a scoped re-import target and shape it like the scanner's output.
// Tight on purpose: workspace-relative, must exist, must be .swift.
async function scopedFileList(
  workspace: string,
  relFile: string,
  deps: Pick<UiImportDeps, 'readFile'>,
): Promise<SwiftFileInfo[]> {
  if (!relFile.endsWith('.swift')) return [];
  const root = path.resolve(workspace);
  const abs = path.resolve(root, relFile);
  if (abs !== root && !abs.startsWith(root + path.sep)) return [];
  let bytes: number;
  try {
    bytes = (await deps.readFile(abs)).length;
  } catch {
    return [];
  }
  return [{ relPath: relFile, bytes, generated: isGeneratedScreenPath(relFile) }];
}

// Kickoff for a scoped re-import: one file, one screen id, replace in place.
export function buildScopedKickoffMessage(
  scope: UiImportScope,
  existing: UISpec,
): string {
  const current = existing.screens.find((s) => s.id === scope.screenId);
  const currentNote = current
    ? `The canvas currently has this screen as "${current.title}" (${current.frame.w}×${current.frame.h}, ${current.nodes.length} nodes); your emit replaces it in place.`
    : `The canvas does not currently have a screen with this id; your emit will add it.`;
  return [
    `Re-import ONE screen from its source file: read \`${scope.file}\` and emit the screen for the View it defines.`,
    '',
    `Emit exactly one screen, and its id MUST be exactly "${scope.screenId}" — this refresh replaces that screen on the canvas. Do not emit any other screens.`,
    `Pass source_file: "${scope.file}".`,
    currentNote,
  ].join('\n');
}

// ── Engine ──────────────────────────────────────────────────────────────────

const MAX_TURNS = 40;

// Minimal structural slice of the API response the loop needs — lets tests
// script responses without fabricating full `Anthropic.Message`s.
export type ImportModelResponse = Pick<
  Anthropic.Message,
  'stop_reason' | 'content'
>;

export type UiImportDeps = {
  listSwiftFiles: (workspace: string) => Promise<SwiftFileInfo[]>;
  readFile: (absPath: string) => Promise<string>;
  getSpec: () => UISpec | null;
  setSpec: (spec: UISpec) => void;
  createMessage: (params: {
    system: string;
    tools: Anthropic.Tool[];
    messages: Anthropic.MessageParam[];
  }) => Promise<ImportModelResponse>;
};

function realCreateMessage(): UiImportDeps['createMessage'] {
  const client = new Anthropic();
  const model = importModel();
  return async ({ system, tools, messages }) => {
    // Streaming keeps long generations under SDK HTTP timeouts; top-level
    // cache_control auto-marks the last cacheable block so each loop
    // iteration re-reads the growing conversation from cache.
    const stream = client.messages.stream({
      model,
      max_tokens: 64_000,
      thinking: { type: 'adaptive' },
      cache_control: { type: 'ephemeral' },
      system: [
        {
          type: 'text',
          text: system,
          cache_control: { type: 'ephemeral' },
        },
      ],
      tools,
      messages,
    });
    return stream.finalMessage();
  };
}

const realDeps: UiImportDeps = {
  listSwiftFiles: findSwiftFiles,
  readFile: (p) => fs.readFile(p, 'utf8'),
  getSpec: () => getHook('getUiMockSpec')?.() ?? null,
  setSpec: (spec) => {
    const set = getHook('setUiMockSpec');
    if (!set) throw new Error('design spec bridge is not available');
    set(spec);
  },
  // Constructed lazily inside runUiImport so a missing API key surfaces as an
  // import error, not a module-load crash.
  createMessage: async (params) => realCreateMessage()(params),
};

function fail(message: string): UiImportState {
  const state: UiImportState = {
    phase: 'error',
    message,
    finishedAt: Date.now(),
  };
  getSlot().state = state;
  return state;
}

// Scoped re-import: refresh ONE screen from its linked source file (the
// chip's refresh action). Same engine, same state machine — the file list is
// pinned to the one file and the model must emit exactly `screenId`.
export type UiImportScope = { file: string; screenId: string };

export async function runUiImport(
  deps: UiImportDeps = realDeps,
  scope?: UiImportScope,
): Promise<UiImportState> {
  const slot = getSlot();
  if (slot.state.phase === 'running') return slot.state;

  const startedAt = Date.now();
  const progress = {
    filesFound: 0,
    filesRead: 0,
    screensImported: 0,
  };
  const setRunning = () => {
    slot.state = { phase: 'running', startedAt, ...progress };
  };
  setRunning();

  const workspace = getWorkspaceOrNull();
  if (!workspace) return fail('no workspace selected');

  let files: SwiftFileInfo[];
  try {
    if (scope) {
      files = await scopedFileList(workspace, scope.file, deps);
    } else {
      files = await deps.listSwiftFiles(workspace);
    }
  } catch (err) {
    return fail(err instanceof Error ? err.message : String(err));
  }
  if (files.length === 0) {
    return fail(
      scope
        ? `source file not found: ${scope.file}`
        : 'no Swift sources found in this workspace',
    );
  }
  progress.filesFound = files.length;
  setRunning();
  const fileSet = new Set(files.map((f) => f.relPath));

  const tools = buildTools();
  const messages: Anthropic.MessageParam[] = [
    {
      role: 'user',
      content: scope
        ? buildScopedKickoffMessage(scope, deps.getSpec() ?? { screens: [] })
        : buildKickoffMessage(files, deps.getSpec() ?? { screens: [] }),
    },
  ];

  let lastText = '';

  const handleToolUse = async (
    block: Anthropic.ToolUseBlock,
  ): Promise<Anthropic.ToolResultBlockParam> => {
    const result = (content: string, isError = false) =>
      ({
        type: 'tool_result',
        tool_use_id: block.id,
        content,
        ...(isError ? { is_error: true } : {}),
      }) satisfies Anthropic.ToolResultBlockParam;

    if (block.name === 'read_swift_file') {
      const rel = (block.input as { path?: unknown }).path;
      if (typeof rel !== 'string' || !fileSet.has(rel)) {
        return result(
          `not a readable workspace file: ${String(rel).slice(0, 200)} — use a path from the provided file list`,
          true,
        );
      }
      try {
        const text = await deps.readFile(path.join(workspace, rel));
        progress.filesRead += 1;
        setRunning();
        return result(
          text.length > READ_FILE_CHAR_CAP
            ? `${text.slice(0, READ_FILE_CHAR_CAP)}\n\n[truncated at ${READ_FILE_CHAR_CAP} characters]`
            : text,
        );
      } catch (err) {
        return result(
          `read failed: ${err instanceof Error ? err.message : String(err)}`,
          true,
        );
      }
    }

    if (block.name === 'emit_screen') {
      const parsed = uiScreenSchema.safeParse(
        (block.input as { screen?: unknown }).screen,
      );
      if (!parsed.success) {
        return result(
          `screen failed validation: ${parsed.error.message.slice(0, 1500)}`,
          true,
        );
      }
      // The server is the sole provenance authority: strip any model-embedded
      // screen.sourceFile and only stamp the allowlist-validated source_file
      // param. Omitting it preserves the prior screen's provenance on replace
      // (see applyEmittedScreen).
      const { sourceFile: _modelEmbedded, ...screenBase } =
        parsed.data as UIScreen;
      const dup = findDuplicateNodeId(screenBase);
      if (dup) {
        return result(
          `screen "${screenBase.id}" has duplicate node id "${dup}" — node ids must be unique`,
          true,
        );
      }
      if (scope && screenBase.id !== scope.screenId) {
        return result(
          `this is a scoped refresh of screen "${scope.screenId}" — emit that exact id (got "${screenBase.id}"), and no other screens`,
          true,
        );
      }
      const src = (block.input as { source_file?: unknown }).source_file;
      let screen: UIScreen = screenBase;
      let note: string | null = null;
      if (typeof src === 'string') {
        if (isGeneratedScreenPath(src)) {
          // TangoGenerated paths are tango's own exports, not provenance —
          // treat as omitted so applyEmittedScreen keeps the prior source.
          note =
            'note: TangoGenerated paths are exports, not provenance — keeping the prior sourceFile';
        } else if (fileSet.has(src)) {
          screen = { ...screenBase, sourceFile: src };
          // Fingerprint the source at import time — the sync watcher compares
          // this against the live file to mark the screen stale later.
          try {
            screen.sourceHash = hashSource(
              await deps.readFile(path.join(workspace, src)),
            );
          } catch {
            // unreadable right now — leave unset (status reads as synced)
          }
        } else {
          note = `note: source_file "${src}" is not in the provided file list — provenance not recorded`;
        }
      }
      try {
        const current = deps.getSpec() ?? { screens: [] };
        deps.setSpec(applyEmittedScreen(current, screen));
      } catch (err) {
        return result(
          `applying screen failed: ${err instanceof Error ? err.message : String(err)}`,
          true,
        );
      }
      progress.screensImported += 1;
      setRunning();
      const warnings = lintScreen(screen);
      if (warnings.length > 0) {
        return result(
          `Imported screen "${screen.id}" (${screen.nodes.length} nodes) WITH LAYOUT WARNINGS — fix these and re-emit the screen with the same id:\n- ${warnings.join('\n- ')}${note ? `\n${note}` : ''}`,
        );
      }
      return result(
        `Imported screen "${screen.id}" (${screen.nodes.length} nodes).${note ? ` ${note}` : ''}`,
      );
    }

    return result(`unknown tool: ${block.name}`, true);
  };

  try {
    for (let turn = 0; turn < MAX_TURNS; turn++) {
      const response = await deps.createMessage({
        system: UI_IMPORT_SYSTEM_PROMPT,
        tools,
        messages,
      });

      for (const blockItem of response.content) {
        if (blockItem.type === 'text') lastText = blockItem.text;
      }

      if (response.stop_reason === 'tool_use') {
        messages.push({ role: 'assistant', content: response.content });
        const toolUses = response.content.filter(
          (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use',
        );
        const results: Anthropic.ToolResultBlockParam[] = [];
        for (const use of toolUses) {
          results.push(await handleToolUse(use));
        }
        messages.push({ role: 'user', content: results });
        continue;
      }

      if (response.stop_reason === 'pause_turn') {
        messages.push({ role: 'assistant', content: response.content });
        continue;
      }

      if (response.stop_reason === 'refusal') {
        return fail('the model declined to process this workspace');
      }
      if (response.stop_reason === 'max_tokens') {
        return fail(
          'the model ran out of output tokens mid-import — try again',
        );
      }

      // end_turn (or null): the model is done.
      break;
    }
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) {
      return fail(
        'Anthropic API authentication failed — set ANTHROPIC_API_KEY in the environment tango runs in',
      );
    }
    return fail(err instanceof Error ? err.message : String(err));
  }

  if (progress.screensImported === 0) {
    return fail(
      lastText
        ? `no screens were imported — ${lastText.slice(0, 300)}`
        : 'no screens were imported',
    );
  }

  const state: UiImportState = {
    phase: 'done',
    ok: true,
    screensImported: progress.screensImported,
    filesRead: progress.filesRead,
    durationMs: Date.now() - startedAt,
    summary: lastText.slice(0, 500),
    finishedAt: Date.now(),
  };
  slot.state = state;
  return state;
}
