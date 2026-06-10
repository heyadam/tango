// In-place export: deterministic codegen spliced into the user's OWN SwiftUI
// sources, then incremental build + launch. The Export & Run orchestration
// (runExportAndRun) lives at the bottom.
//
// The write model (no LLM anywhere):
//   - A screen LINKED to a source file (screen.sourceFile, stamped at import)
//     gets its View struct's `var body` replaced with regenerated code —
//     swiftScan locates the struct/body with a string/comment/interpolation-
//     aware scanner and touches nothing outside the two body braces. Because
//     the edited views are the ones the app actually renders, the simulator
//     shows the design immediately after the build — no wiring step.
//   - A screen with NO source tie gets a fresh `<TypeName>.swift` at the app
//     source root, then is linked to it (provenance restamped), so the next
//     export edits it in place. New files still need the user (or agent) to
//     wire the view into navigation — surfaced in the result.
//   - Two guard rails: a linked file whose content changed since import
//     (sourceHash mismatch) is only overwritten when its current body already
//     carries the tango:body marker — hand-written edits are never clobbered,
//     the screen is skipped with a "refresh first" reason instead. And every
//     modified file's pre-export content lands in .tango/export-backup/.
//   - The retired TangoGenerated/ output of the old whole-file paradigm is
//     cleaned up (marked files only), unless user code still references those
//     types — deleting them would break the build.
//
// Whether a NEW file joins the build automatically depends on the project
// format: Xcode 16 fs-synced groups pick it up ('fs-synced'); legacy PBXGroup
// projects need a one-time manual add ('manual-add-required') — we never
// auto-edit a pbxproj. In-place edits to existing sources have no such
// concern; the files are already in the target.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { atomicWrite } from './fsAtomic';
import {
  GENERATED_MARKER,
  emitScreenBody,
  emitScreenFile,
  newScreenTypeNames,
  structCandidates,
} from '@/lib/specToSwiftUI';
import {
  bodyHasMarker,
  codeContainsWord,
  declaredTypeNames,
  findViewStructBody,
  replaceStructBody,
  type FindBodyFailure,
} from '@/lib/swiftScan';
import { resolveSpec } from '@/lib/uiResolve';
import { hashSource } from './sourceHash';
import type { IosProject } from './iosBuild';
import { SKIP_DIRS, iosBuildRun, resolveActiveUdid } from './iosBuild';
import { getIosProject, getWorkspaceOrNull } from './workspace';
import { getHook } from './serverHooks';
import type { UISpec } from '@/lib/uiMockProtocol';

export const GENERATED_DIR_NAME = 'TangoGenerated';
// Pre-export originals, one mirror path per modified file. Superseded PER
// FILE when that file is next modified — never wiped wholesale: a retry
// after a failed build must not destroy the only copy of a hand-written
// body the failed run had just replaced.
export const BACKUP_DIR = path.join('.tango', 'export-backup');

export type GeneratedDirInclusion = 'fs-synced' | 'manual-add-required';

// ── fs seam ─────────────────────────────────────────────────────────────────
// Every disk touch goes through this so the splice/create/cleanup logic is
// testable against an in-memory map.

export type ExportFs = {
  readFile: (abs: string) => Promise<string>;
  /** Atomic write; creates parent directories. */
  writeFile: (abs: string, content: string) => Promise<void>;
  exists: (abs: string) => Promise<boolean>;
  readdir: (
    abs: string,
  ) => Promise<Array<{ name: string; dir: boolean; file: boolean }>>;
  unlink: (abs: string) => Promise<void>;
  /** Remove a directory only if it is empty; silent no-op otherwise. */
  rmdirIfEmpty: (abs: string) => Promise<void>;
  /** Recursive force-remove (backup-dir reset). */
  rmrf: (abs: string) => Promise<void>;
};

export const realExportFs: ExportFs = {
  readFile: (p) => fs.readFile(p, 'utf8'),
  writeFile: async (p, content) => {
    await fs.mkdir(path.dirname(p), { recursive: true });
    await atomicWrite(p, content);
  },
  exists: async (p) => {
    try {
      await fs.stat(p);
      return true;
    } catch {
      return false;
    }
  },
  readdir: async (p) => {
    const entries = await fs.readdir(p, { withFileTypes: true });
    return entries.map((e) => ({
      name: e.name,
      dir: e.isDirectory(),
      file: e.isFile(),
    }));
  },
  unlink: (p) => fs.unlink(p),
  rmdirIfEmpty: async (p) => {
    try {
      await fs.rmdir(p);
    } catch {
      /* not empty / already gone */
    }
  },
  rmrf: (p) => fs.rm(p, { recursive: true, force: true }),
};

// ── source root resolution ──────────────────────────────────────────────────

// App source root: the folder conventionally named after the project stem
// (where the app target's sources live), falling back to the scheme name,
// then the project dir itself. New screen files land here; `inclusion` says
// whether the project picks them up automatically (Xcode 16 fs-synced
// groups) or needs a one-time manual add.
export async function resolveSourceRoot(
  project: IosProject,
  fsx: ExportFs = realExportFs,
): Promise<{ sourceRoot: string; inclusion: GeneratedDirInclusion }> {
  const projDir = path.dirname(project.projectPath);
  const stem = path.basename(
    project.projectPath,
    path.extname(project.projectPath),
  );

  // For a .xcworkspace, the pbxproj lives in the sibling same-stem .xcodeproj.
  const xcodeprojPath = project.projectPath.endsWith('.xcworkspace')
    ? path.join(projDir, `${stem}.xcodeproj`)
    : project.projectPath;
  const pbxprojPath = path.join(xcodeprojPath, 'project.pbxproj');

  let sourceRoot = path.join(projDir, stem);
  if (!(await fsx.exists(sourceRoot))) {
    const byScheme = path.join(projDir, project.scheme);
    sourceRoot = (await fsx.exists(byScheme)) ? byScheme : projDir;
  }

  let inclusion: GeneratedDirInclusion = 'manual-add-required';
  try {
    const pbxproj = await fsx.readFile(pbxprojPath);
    if (
      pbxproj.includes('PBXFileSystemSynchronizedRootGroup') &&
      sourceRoot !== projDir
    ) {
      inclusion = 'fs-synced';
    }
  } catch {
    // unreadable pbxproj — assume manual
  }
  return { sourceRoot, inclusion };
}

// ── project scanning ────────────────────────────────────────────────────────

const MAX_SCAN_DEPTH = 8;
const MAX_SCAN_FILES = 2000; // read cap so a pathological tree can't stall

// Walk the project's user-authored .swift files (skipping toolchain dirs,
// TangoGenerated/, and tango:generated-marked files). `visit` returning true
// stops the walk early.
async function walkUserSwift(
  rootDir: string,
  fsx: ExportFs,
  visit: (abs: string, content: string) => boolean | undefined,
): Promise<void> {
  let budget = MAX_SCAN_FILES;
  async function walk(dir: string, depth: number): Promise<boolean> {
    if (depth > MAX_SCAN_DEPTH || budget <= 0) return false;
    let entries;
    try {
      entries = await fsx.readdir(dir);
    } catch {
      return false;
    }
    for (const e of entries) {
      if (e.dir) {
        if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
        if (e.name === GENERATED_DIR_NAME) continue;
        if (e.name.endsWith('.xcodeproj') || e.name.endsWith('.xcworkspace')) continue;
        if (await walk(path.join(dir, e.name), depth + 1)) return true;
        continue;
      }
      if (!e.file || !e.name.endsWith('.swift')) continue;
      if (budget-- <= 0) return false;
      let content: string;
      try {
        content = await fsx.readFile(path.join(dir, e.name));
      } catch {
        continue;
      }
      const head = content.split('\n').slice(0, 3).join('\n');
      if (head.includes(GENERATED_MARKER)) continue;
      if (visit(path.join(dir, e.name), content)) return true;
    }
    return false;
  }
  await walk(rootDir, 0);
}

// Every type name declared in the project's user sources — the collision set
// for naming new screen files.
export async function scanProjectTypes(
  projectDir: string,
  fsx: ExportFs = realExportFs,
): Promise<Set<string>> {
  const out = new Set<string>();
  await walkUserSwift(projectDir, fsx, (_abs, content) => {
    for (const name of declaredTypeNames(content)) out.add(name);
    return undefined;
  });
  return out;
}

// Does any user source mention one of these type names? (Substring check —
// cheap, and a false positive only means we conservatively keep legacy files.)
export async function projectReferencesTypes(
  projectDir: string,
  typeNames: string[],
  fsx: ExportFs = realExportFs,
): Promise<boolean> {
  if (typeNames.length === 0) return false;
  let found = false;
  await walkUserSwift(projectDir, fsx, (_abs, content) => {
    if (typeNames.some((t) => content.includes(t))) {
      found = true;
      return true;
    }
    return undefined;
  });
  return found;
}

// ── legacy TangoGenerated cleanup ───────────────────────────────────────────

// Remove the retired whole-file paradigm's output: tango:generated-marked
// .swift files under <sourceRoot>/TangoGenerated/. If user code still
// references the generated types (the old "embed TangoGeneratedRootView"
// wiring), deleting them would break the build — keep them and report it.
export async function cleanupLegacyGenerated(
  sourceRoot: string,
  projectDir: string,
  fsx: ExportFs = realExportFs,
): Promise<{ removed: number; kept: boolean }> {
  const dir = path.join(sourceRoot, GENERATED_DIR_NAME);
  if (!(await fsx.exists(dir))) return { removed: 0, kept: false };

  let entries: Array<{ name: string; dir: boolean; file: boolean }>;
  try {
    entries = await fsx.readdir(dir);
  } catch {
    return { removed: 0, kept: false };
  }
  const swiftFiles = entries.filter((e) => e.file && e.name.endsWith('.swift'));
  if (swiftFiles.length === 0) {
    await fsx.rmdirIfEmpty(dir);
    return { removed: 0, kept: false };
  }

  const typeNames = [
    'TangoGeneratedRootView',
    ...swiftFiles.map((e) => e.name.replace(/\.swift$/, '')),
  ];
  if (await projectReferencesTypes(projectDir, typeNames, fsx)) {
    return { removed: 0, kept: true };
  }

  let removed = 0;
  for (const e of swiftFiles) {
    const abs = path.join(dir, e.name);
    try {
      const head = (await fsx.readFile(abs)).split('\n').slice(0, 3).join('\n');
      if (!head.includes(GENERATED_MARKER)) continue; // never touch unmarked files
      await fsx.unlink(abs);
      removed += 1;
    } catch {
      /* skip unreadable entries */
    }
  }
  await fsx.rmdirIfEmpty(dir);
  return { removed, kept: false };
}

// ── in-place export ─────────────────────────────────────────────────────────

export type ScreenExportAction = 'updated' | 'unchanged' | 'created' | 'skipped';

export type ScreenExportResult = {
  screenId: string;
  /** Workspace-relative target file ('' when skipped before one resolved). */
  file: string;
  /** The View struct that was written (absent when skipped early). */
  struct?: string;
  action: ScreenExportAction;
  /** Why the screen was skipped (action 'skipped' only). */
  reason?: string;
};

export type InPlaceExportOutcome = {
  results: ScreenExportResult[];
  /** screenId → fresh provenance to restamp on the live spec. */
  provenance: Map<string, { sourceFile: string; sourceHash: string }>;
  /** Workspace-relative files whose pre-export content was backed up. */
  backedUp: string[];
  legacy: { removed: number; kept: boolean };
};

function spliceFailureReason(
  reason: FindBodyFailure,
  struct: string,
  file: string,
  candidates: string[],
): string {
  switch (reason) {
    case 'struct-not-found':
      return `no struct named ${candidates.join(' / ')} in ${file} — re-import the screen to relink it`;
    case 'struct-ambiguous':
      return `${file} declares several structs named ${struct} — rename one (or re-import) so the screen's target is unambiguous`;
    case 'body-not-found':
      return `struct ${struct} in ${file} has no computed \`var body\` to replace`;
    default:
      return `couldn't safely parse ${file} around ${struct} (${reason}) — file left untouched`;
  }
}

// Resolve a workspace-relative provenance path, refusing anything that
// escapes the workspace (same policy as the source-sync reader).
function safeWorkspacePath(workspace: string, rel: string): string | null {
  const root = path.resolve(workspace);
  const abs = path.resolve(root, rel);
  if (abs !== root && !abs.startsWith(root + path.sep)) return null;
  return abs;
}

/**
 * Write the spec into the project: splice linked screens' bodies in place,
 * create files for unlinked screens, back up everything modified, clean up
 * the legacy TangoGenerated/ output. Pure orchestration over the fs seam —
 * no globals, no build. Never throws for per-screen problems; they come back
 * as 'skipped' results. Throws only on infrastructure failures (backup dir,
 * write errors), which the caller maps to the 'write' error stage.
 */
export async function applyInPlaceExport(args: {
  spec: UISpec;
  workspace: string;
  sourceRoot: string;
  projectDir: string;
  fsx?: ExportFs;
}): Promise<InPlaceExportOutcome> {
  const { workspace, sourceRoot, projectDir } = args;
  const fsx = args.fsx ?? realExportFs;

  // A legacy sourceFile pointing INTO TangoGenerated/ is an old export, not
  // user provenance — shed it so the screen exports as a fresh real file
  // (and gets restamped) instead of splicing into the folder the legacy
  // cleanup below may remove.
  const normalizedScreens = args.spec.screens.map((s) => {
    if (!s.sourceFile?.split(path.sep).includes(GENERATED_DIR_NAME)) return s;
    const { sourceFile: _f, sourceHash: _h, ...rest } = s;
    return rest;
  });
  const spec: UISpec = normalizedScreens.some((s, i) => s !== args.spec.screens[i])
    ? { ...args.spec, screens: normalizedScreens }
    : args.spec;

  const resolved = resolveSpec(spec);
  const resolvedById = new Map(resolved.screens.map((s) => [s.id, s]));
  const results: ScreenExportResult[] = [];
  const provenance = new Map<string, { sourceFile: string; sourceHash: string }>();
  const backedUp: string[] = [];
  const backupRoot = path.join(workspace, BACKUP_DIR);

  // Linked screens, grouped by source file (several screens can live in one
  // file — TodoListView and AuthView both in ContentView.swift).
  const linkedByFile = new Map<string, typeof spec.screens>();
  const unlinked: typeof spec.screens = [];
  for (const screen of spec.screens) {
    if (screen.sourceFile) {
      const list = linkedByFile.get(screen.sourceFile) ?? [];
      list.push(screen);
      linkedByFile.set(screen.sourceFile, list);
    } else {
      unlinked.push(screen);
    }
  }

  // Legacy cleanup and the project-type scan run BEFORE the splice writes:
  // both walk up to 2000 files, and sitting between the last linked-file
  // write and the provenance restamp they could outlast the source-sync
  // watcher's 300ms debounce — the chips would flap 'stale' against the
  // not-yet-restamped hashes.
  const legacy = await cleanupLegacyGenerated(sourceRoot, projectDir, fsx);
  const newFileNames =
    unlinked.length > 0
      ? newScreenTypeNames(spec, await scanProjectTypes(projectDir, fsx))
      : new Map<string, string>();

  // App-shell containers a DESIGN body never contains: a hand-written body
  // built around one of these is the app's navigation scaffolding, which the
  // canvas cannot represent — overwriting it with absolutely-positioned boxes
  // would disconnect every real screen from the running app. (NavigationStack
  // is deliberately absent: real screens wrap themselves in one for title
  // bars; the shell signals are hosting OTHER canvas screens or the
  // tab/split/scene containers below.)
  const SHELL_CONTAINERS = ['TabView', 'NavigationSplitView', 'WindowGroup'];
  const candidatesByScreen = new Map(
    spec.screens.map((s) => [s.id, structCandidates(s)]),
  );

  for (const [rel, screens] of linkedByFile) {
    const abs = safeWorkspacePath(workspace, rel);
    if (!abs) {
      for (const s of screens) {
        results.push({
          screenId: s.id,
          file: rel,
          action: 'skipped',
          reason: `source path escapes the workspace: ${rel}`,
        });
      }
      continue;
    }
    let original: string;
    try {
      original = await fsx.readFile(abs);
    } catch {
      for (const s of screens) {
        results.push({
          screenId: s.id,
          file: rel,
          action: 'skipped',
          reason: `source file is missing: ${rel} — re-import or remove the screen`,
        });
      }
      continue;
    }

    const originalHash = hashSource(original);
    let text = original;
    const usedStructs = new Set<string>();
    const written: string[] = []; // screen ids spliced into this file

    for (const screen of screens) {
      const candidates = structCandidates(screen).filter(
        (c) => !usedStructs.has(c),
      );
      let structName: string | null = null;
      let failure: FindBodyFailure = 'struct-not-found';
      for (const c of candidates) {
        const found = findViewStructBody(text, c);
        if (found.ok) {
          structName = c;
          break;
        }
        // struct-not-found keeps trying; a located-but-broken struct stops.
        if (found.reason !== 'struct-not-found') {
          structName = c;
          failure = found.reason;
          break;
        }
      }
      if (structName === null || failure !== 'struct-not-found') {
        const struct = structName ?? candidates[0] ?? screen.id;
        results.push({
          screenId: screen.id,
          file: rel,
          struct,
          action: 'skipped',
          reason: spliceFailureReason(
            structName === null ? 'struct-not-found' : failure,
            struct,
            rel,
            candidates,
          ),
        });
        continue;
      }

      const located = findViewStructBody(text, structName);
      if (!located.ok) continue; // unreachable — just located above
      const marked = bodyHasMarker(text, located.loc);

      // Navigation-shell guard: an UNMARKED body that hosts other canvas
      // screens (ContentView { TabView { TodoListView(); AuthView() } }) or
      // is built around an app-shell container is the app's navigation
      // scaffolding — overwriting it would replace the real tab bar /
      // routing with static boxes and disconnect the designed screens from
      // the running app. Skip it; the design lives in its destinations.
      if (!marked) {
        const interior = text.slice(
          located.loc.bodyOpen + 1,
          located.loc.bodyClose,
        );
        const ownNames = new Set(candidatesByScreen.get(screen.id) ?? []);
        const otherScreenStructs = [
          ...new Set(
            spec.screens
              .filter((s) => s.id !== screen.id)
              .flatMap((s) => candidatesByScreen.get(s.id) ?? [])
              .filter((n) => !ownNames.has(n)),
          ),
        ];
        const hosted = codeContainsWord(interior, otherScreenStructs);
        const container = hosted
          ? null
          : codeContainsWord(interior, SHELL_CONTAINERS);
        if (hosted || container) {
          results.push({
            screenId: screen.id,
            file: rel,
            struct: structName,
            action: 'skipped',
            reason: hosted
              ? `${structName} is the app's navigation shell (its body shows ${hosted}, another canvas screen) — tango never overwrites navigation; delete the "${screen.id}" screen from the canvas and design its destination screens instead`
              : `${structName}'s body is built around a ${container} — it looks like the app's navigation shell, which tango never overwrites; design its destination screens instead (or remove this screen from the canvas)`,
          });
          continue;
        }
      }

      // Stale guard: the file changed since this screen was imported. Only a
      // body that is provably tango-generated (marker) is safe to overwrite —
      // hand-written changes get a refresh-first skip, never clobbered.
      const stale =
        screen.sourceHash !== undefined && originalHash !== screen.sourceHash;
      if (stale && !marked) {
        results.push({
          screenId: screen.id,
          file: rel,
          struct: structName,
          action: 'skipped',
          reason: `${rel} changed since this screen was imported — refresh the screen (↻) and export again`,
        });
        continue;
      }

      const body = emitScreenBody(resolvedById.get(screen.id)!);
      const spliced = replaceStructBody(text, structName, body);
      if (!spliced.ok) {
        results.push({
          screenId: screen.id,
          file: rel,
          struct: structName,
          action: 'skipped',
          reason: spliceFailureReason(spliced.reason, structName, rel, candidates),
        });
        continue;
      }
      text = spliced.source;
      usedStructs.add(structName);
      written.push(screen.id);
      results.push({
        screenId: screen.id,
        file: rel,
        struct: structName,
        action: spliced.changed ? 'updated' : 'unchanged',
      });
    }

    if (text !== original) {
      await fsx.writeFile(path.join(backupRoot, rel), original);
      backedUp.push(rel);
      await fsx.writeFile(abs, text);
    }
    // Restamp every successfully written screen to the file's NEW content —
    // the source-sync chip stays 'synced'. Skipped screens keep their stale
    // hash on purpose: their chip turning warning-tinted is the signal.
    const newHash = hashSource(text);
    for (const id of written) {
      provenance.set(id, { sourceFile: rel, sourceHash: newHash });
    }
  }

  // Canvas-born screens → fresh files at the source root, named clear of the
  // project's declared types, then linked so the next export splices in place.
  if (unlinked.length > 0) {
    for (const screen of unlinked) {
      const typeName = newFileNames.get(screen.id)!;
      const abs = path.join(sourceRoot, `${typeName}.swift`);
      const rel = path.relative(workspace, abs);
      if (await fsx.exists(abs)) {
        // A file by this name exists but declares no such type (else the
        // scan would have excluded the name) — don't gamble, skip loudly.
        results.push({
          screenId: screen.id,
          file: rel,
          struct: typeName,
          action: 'skipped',
          reason: `${rel} already exists — rename the screen or remove the file`,
        });
        continue;
      }
      const content = emitScreenFile(resolvedById.get(screen.id)!, typeName);
      await fsx.writeFile(abs, content);
      results.push({
        screenId: screen.id,
        file: rel,
        struct: typeName,
        action: 'created',
      });
      provenance.set(screen.id, {
        sourceFile: rel,
        sourceHash: hashSource(content),
      });
    }
  }

  return { results, provenance, backedUp, legacy };
}

// Restamp screen provenance (sourceFile/sourceHash) onto the LIVE spec after
// an export wrote files. Field-level patch against the current cache — node
// edits that landed mid-export survive untouched. Returns null when nothing
// changes (skip the broadcast).
export function patchScreenProvenance(
  spec: UISpec,
  provenance: Map<string, { sourceFile: string; sourceHash: string }>,
): UISpec | null {
  let changed = false;
  const screens = spec.screens.map((s) => {
    const p = provenance.get(s.id);
    if (!p) return s;
    if (s.sourceFile === p.sourceFile && s.sourceHash === p.sourceHash) return s;
    changed = true;
    return { ...s, sourceFile: p.sourceFile, sourceHash: p.sourceHash };
  });
  return changed ? { ...spec, screens } : null;
}

// ── Export & Run orchestration ────────────────────────────────────────────

export type ExportRunState =
  | { phase: 'idle' }
  | {
      phase: 'generating' | 'writing' | 'building' | 'installing' | 'launching';
      startedAt: number;
    }
  | {
      phase: 'done';
      ok: true;
      bundleId: string;
      pid: number | null;
      durationMs: number;
      results: ScreenExportResult[];
      // Whether NEW files join the build automatically ('fs-synced') or need
      // a one-time manual add in Xcode. Irrelevant for in-place edits.
      inclusion: GeneratedDirInclusion;
      finishedAt: number;
    }
  | {
      phase: 'error';
      stage: 'spec' | 'detect' | 'generate' | 'write' | 'build' | 'install' | 'launch';
      message: string;
      errors: string[];
      finishedAt: number;
    };

type ExportRunSlot = { state: ExportRunState };

const SLOT_KEY = '__tangoExportRunSlot__';

function getSlot(): ExportRunSlot {
  const g = globalThis as typeof globalThis & { [SLOT_KEY]?: ExportRunSlot };
  if (!g[SLOT_KEY]) g[SLOT_KEY] = { state: { phase: 'idle' } };
  return g[SLOT_KEY];
}

export function getExportRunState(): ExportRunState {
  return getSlot().state;
}

function isActive(state: ExportRunState): boolean {
  return (
    state.phase === 'generating' ||
    state.phase === 'writing' ||
    state.phase === 'building' ||
    state.phase === 'installing' ||
    state.phase === 'launching'
  );
}

export function isExportRunActive(): boolean {
  return isActive(getSlot().state);
}

function fail(
  stage: Extract<ExportRunState, { phase: 'error' }>['stage'],
  message: string,
  errors: string[] = [],
): ExportRunState {
  const state: ExportRunState = {
    phase: 'error',
    stage,
    message,
    errors,
    finishedAt: Date.now(),
  };
  getSlot().state = state;
  return state;
}

// Resolve the project to build from the workspace slot's detection status —
// the same precedence the ios_build_run MCP tool applies, shared so the two
// paths can't drift.
export function resolveBuildProject(
  scheme: string | undefined,
): { ok: true; project: IosProject } | { ok: false; message: string } {
  const status = getIosProject();
  if (status.kind === 'none') {
    return {
      ok: false,
      message:
        'no Xcode project detected in this workspace (need a *.xcodeproj or *.xcworkspace at depth ≤ 3)',
    };
  }
  if (status.kind === 'error') {
    return { ok: false, message: status.message };
  }
  if (status.kind === 'detected') {
    return { ok: true, project: status.project };
  }
  // ambiguous
  if (!scheme) {
    return {
      ok: false,
      message:
        'multiple Xcode projects detected; pass an explicit `scheme` matching one of the candidates (call `ios_status` to see them)',
    };
  }
  const matches = status.candidates.filter((c) => c.schemes.includes(scheme));
  if (matches.length === 0) {
    return {
      ok: false,
      message: `scheme "${scheme}" not found in any detected Xcode project`,
    };
  }
  if (matches.length > 1) {
    const paths = matches.map((m) => m.projectPath).join(', ');
    return {
      ok: false,
      message: `scheme "${scheme}" matches multiple Xcode projects (${paths}); rename the scheme in one of them or remove the unwanted project from the workspace to disambiguate`,
    };
  }
  return {
    ok: true,
    project: {
      projectPath: matches[0].projectPath,
      projectKind: matches[0].projectKind,
      scheme,
      bundleId: null,
      configurations: ['Debug', 'Release'],
    },
  };
}

export type ExportRunOpts = {
  scheme?: string;
  udid?: string;
  configuration?: 'Debug' | 'Release';
};

// Injectable deps so the state machine is testable without xcodebuild.
type ExportRunDeps = {
  getSpec: () => UISpec | null;
  setSpec: (spec: UISpec) => void;
  buildRun: typeof iosBuildRun;
  resolveUdid: typeof resolveActiveUdid;
  resolveRoot: (
    project: IosProject,
  ) => Promise<{ sourceRoot: string; inclusion: GeneratedDirInclusion }>;
  fsx: ExportFs;
};

const realDeps: ExportRunDeps = {
  getSpec: () => getHook('getUiMockSpec')?.() ?? null,
  setSpec: (spec) => {
    getHook('setUiMockSpec')?.(spec);
  },
  buildRun: iosBuildRun,
  resolveUdid: resolveActiveUdid,
  resolveRoot: (project) => resolveSourceRoot(project),
  fsx: realExportFs,
};

// Deterministic codegen → splice into the user's sources → incremental build
// → install → launch. No LLM anywhere. Returns the final state (also readable
// via getExportRunState while in flight).
export async function runExportAndRun(
  opts: ExportRunOpts = {},
  deps: ExportRunDeps = realDeps,
): Promise<ExportRunState> {
  const slot = getSlot();
  if (isActive(slot.state)) return slot.state;

  const startedAt = Date.now();
  slot.state = { phase: 'generating', startedAt };

  const workspace = getWorkspaceOrNull();
  if (!workspace) return fail('detect', 'no workspace selected');

  const spec = deps.getSpec();
  if (!spec || spec.screens.length === 0) {
    return fail('spec', 'the design canvas is empty — nothing to export');
  }

  const projectResult = resolveBuildProject(opts.scheme);
  if (!projectResult.ok) return fail('detect', projectResult.message);
  const project = projectResult.project;
  const projectDir = path.dirname(project.projectPath);

  let target;
  try {
    target = await deps.resolveRoot(project);
  } catch (err) {
    return fail('generate', err instanceof Error ? err.message : String(err));
  }

  slot.state = { phase: 'writing', startedAt };
  let outcome: InPlaceExportOutcome;
  try {
    outcome = await applyInPlaceExport({
      spec,
      workspace,
      sourceRoot: target.sourceRoot,
      projectDir,
      fsx: deps.fsx,
    });
  } catch (err) {
    return fail('write', err instanceof Error ? err.message : String(err));
  }

  if (outcome.results.every((r) => r.action === 'skipped')) {
    return fail(
      'write',
      'no screen could be exported',
      outcome.results.map((r) => `${r.screenId}: ${r.reason ?? 'skipped'}`),
    );
  }

  // Restamp provenance BEFORE the (slow) build so the source-sync watcher
  // sees fresh hashes the moment it notices our writes — chips stay 'synced'
  // instead of flashing stale for the length of an xcodebuild.
  const current = deps.getSpec();
  if (current) {
    const patched = patchScreenProvenance(current, outcome.provenance);
    if (patched) deps.setSpec(patched);
  }

  const udid = await deps.resolveUdid(opts.udid);
  if (!udid) {
    return fail(
      'detect',
      'no booted iOS simulator (boot one from Xcode → Open Developer Tool → Simulator)',
    );
  }

  slot.state = { phase: 'building', startedAt };
  const result = await deps.buildRun(workspace, project, {
    scheme: opts.scheme,
    udid,
    configuration: opts.configuration,
    bringForeground: true,
  });

  if (!result.ok) {
    const note =
      outcome.backedUp.length > 0
        ? ` (pre-export originals: ${BACKUP_DIR}/)`
        : '';
    return fail(result.stage, result.message + note, result.errors);
  }

  const state: ExportRunState = {
    phase: 'done',
    ok: true,
    bundleId: result.bundleId,
    pid: result.pid ?? null,
    durationMs: Date.now() - startedAt,
    results: outcome.results,
    inclusion: target.inclusion,
    finishedAt: Date.now(),
  };
  slot.state = state;
  return state;
}
