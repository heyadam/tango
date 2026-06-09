// Where deterministic codegen output lands inside the user's Xcode project,
// and how it gets written. The Export & Run orchestration (runExportAndRun)
// lives here too — see the bottom half.
//
// Generated files go to `<app source root>/TangoGenerated/`. Whether Xcode
// picks them up automatically depends on the project format:
//   - Xcode 16+ projects use filesystem-synchronized root groups
//     (PBXFileSystemSynchronizedRootGroup in the pbxproj) — folder members
//     auto-join the target, so dropping files in just works.
//   - Older PBXGroup-based projects need a one-time manual add in Xcode
//     (drag TangoGenerated/ into the target). We surface that as
//     `inclusion: 'manual-add-required'` and never auto-edit the pbxproj —
//     corrupting a user's project file is the worse failure.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { atomicWrite } from './fsAtomic';
import { GENERATED_MARKER, specToSwiftUI } from '@/lib/specToSwiftUI';
import type { GeneratedFile } from '@/lib/specToSwiftUI';
import type { IosProject } from './iosBuild';
import { SKIP_DIRS, iosBuildRun, resolveActiveUdid } from './iosBuild';
import { getIosProject, getWorkspaceOrNull } from './workspace';
import { getHook } from './serverHooks';
import type { UISpec } from '@/lib/uiMockProtocol';

export const GENERATED_DIR_NAME = 'TangoGenerated';

export type GeneratedDirInclusion = 'fs-synced' | 'manual-add-required';

// Pure-ish core, injectable reader for tests.
export async function resolveGeneratedDir(
  project: IosProject,
  readFile: (p: string) => Promise<string> = (p) => fs.readFile(p, 'utf8'),
  exists: (p: string) => Promise<boolean> = async (p) => {
    try {
      await fs.stat(p);
      return true;
    } catch {
      return false;
    }
  },
): Promise<{ dir: string; inclusion: GeneratedDirInclusion }> {
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

  // App source root: the folder conventionally named after the project stem
  // (where the app target's sources live). Fall back to the scheme name, then
  // to the project dir itself.
  let sourceRoot = path.join(projDir, stem);
  if (!(await exists(sourceRoot))) {
    const bySheme = path.join(projDir, project.scheme);
    sourceRoot = (await exists(bySheme)) ? bySheme : projDir;
  }
  const dir = path.join(sourceRoot, GENERATED_DIR_NAME);

  let inclusion: GeneratedDirInclusion = 'manual-add-required';
  try {
    const pbxproj = await readFile(pbxprojPath);
    if (
      pbxproj.includes('PBXFileSystemSynchronizedRootGroup') &&
      sourceRoot !== projDir
    ) {
      inclusion = 'fs-synced';
    }
  } catch {
    // unreadable pbxproj — assume manual
  }
  return { dir, inclusion };
}

// Write the generated set, then delete any stale *.swift in the dir that (a)
// carries the tango:generated marker in its first lines and (b) isn't part of
// the new set. Never touches unmarked files.
export async function writeGeneratedFiles(
  dir: string,
  files: GeneratedFile[],
): Promise<void> {
  await fs.mkdir(dir, { recursive: true });
  const keep = new Set(files.map((f) => f.path));

  for (const f of files) {
    await atomicWrite(path.join(dir, f.path), f.content);
  }

  let entries: string[] = [];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.endsWith('.swift') || keep.has(entry)) continue;
    try {
      const head = await fs.readFile(path.join(dir, entry), 'utf8');
      const firstLines = head.split('\n').slice(0, 3).join('\n');
      if (firstLines.includes(GENERATED_MARKER)) {
        await fs.unlink(path.join(dir, entry));
      }
    } catch {
      /* skip unreadable entries */
    }
  }
}

// Generated views render nothing until some user source references them —
// exporting into a freshly-created Xcode project builds and launches fine
// while the app on screen stays the stock template, which reads as "export
// did nothing". Detecting that is cheap and deterministic: scan the project
// dir's .swift files (skipping the toolchain dirs and anything carrying the
// tango:generated marker) for any embeddable type name. We surface the
// result; wiring `TangoGeneratedRootView()` into user code is the user's or
// the agent's move, never this pipeline's.
export async function detectDesignEmbedded(
  projectDir: string,
  typeNames: string[],
  maxDepth = 8,
): Promise<boolean> {
  if (typeNames.length === 0) return false;
  let budget = 2000; // file-read cap so a pathological tree can't stall the export
  async function walk(dir: string, depth: number): Promise<boolean> {
    if (depth > maxDepth || budget <= 0) return false;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return false;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
        if (e.name === GENERATED_DIR_NAME) continue;
        if (e.name.endsWith('.xcodeproj') || e.name.endsWith('.xcworkspace')) continue;
        if (await walk(path.join(dir, e.name), depth + 1)) return true;
        continue;
      }
      if (!e.isFile() || !e.name.endsWith('.swift')) continue;
      if (budget-- <= 0) return false;
      let content: string;
      try {
        content = await fs.readFile(path.join(dir, e.name), 'utf8');
      } catch {
        continue;
      }
      const head = content.split('\n').slice(0, 3).join('\n');
      if (head.includes(GENERATED_MARKER)) continue;
      if (typeNames.some((t) => content.includes(t))) return true;
    }
    return false;
  }
  return walk(projectDir, 0);
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
      fileCount: number;
      inclusion: GeneratedDirInclusion;
      generatedDir: string;
      // false → no user Swift references the generated views; the launched
      // app looks unchanged until TangoGeneratedRootView() (or a screen
      // view) is embedded somewhere.
      embedded: boolean;
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
  buildRun: typeof iosBuildRun;
  resolveUdid: typeof resolveActiveUdid;
  resolveDir: (project: IosProject) => Promise<{ dir: string; inclusion: GeneratedDirInclusion }>;
  writeFiles: typeof writeGeneratedFiles;
  checkEmbedded: (projectDir: string, typeNames: string[]) => Promise<boolean>;
};

const realDeps: ExportRunDeps = {
  getSpec: () => getHook('getUiMockSpec')?.() ?? null,
  buildRun: iosBuildRun,
  resolveUdid: resolveActiveUdid,
  resolveDir: (project) => resolveGeneratedDir(project),
  writeFiles: writeGeneratedFiles,
  checkEmbedded: detectDesignEmbedded,
};

// Deterministic codegen → write into the project → incremental build →
// install → launch. No LLM anywhere. Returns the final state (also readable
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

  let files;
  let embedTypeNames: string[];
  let target;
  try {
    target = await deps.resolveDir(project);
    ({ files, embedTypeNames } = specToSwiftUI(spec));
  } catch (err) {
    return fail('generate', err instanceof Error ? err.message : String(err));
  }

  slot.state = { phase: 'writing', startedAt };
  try {
    await deps.writeFiles(target.dir, files);
  } catch (err) {
    return fail('write', err instanceof Error ? err.message : String(err));
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
    return fail(result.stage, result.message, result.errors);
  }

  // A scan failure must not fail an export that built and launched — assume
  // embedded (a missing warning beats a false one).
  let embedded = true;
  try {
    embedded = await deps.checkEmbedded(
      path.dirname(project.projectPath),
      embedTypeNames,
    );
  } catch {
    /* keep embedded = true */
  }

  const state: ExportRunState = {
    phase: 'done',
    ok: true,
    bundleId: result.bundleId,
    pid: result.pid ?? null,
    durationMs: Date.now() - startedAt,
    fileCount: files.length,
    inclusion: target.inclusion,
    generatedDir: target.dir,
    embedded,
    finishedAt: Date.now(),
  };
  slot.state = state;
  return state;
}
