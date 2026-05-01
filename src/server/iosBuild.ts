// iOS simulator build / install / launch pipeline.
//
// Pure-ish helpers used by the MCP tools (`ios_status`, `ios_build_run`,
// `ios_logs_recent`). All command spawns go through `runCommand` so timeouts
// and arg-array hygiene are uniform; nothing is interpolated into a shell. The
// only function with a unit test is `parseBuildErrors` — the rest hits the
// macOS toolchain and is exercised manually.

import { spawn } from 'node:child_process';
import { type Dirent, promises as fs } from 'node:fs';
import path from 'node:path';

export type IosProjectKind = 'project' | 'workspace';

export type IosProject = {
  projectPath: string; // absolute
  projectKind: IosProjectKind;
  scheme: string;
  bundleId: string | null;
  configurations: string[];
};

export type IosProjectStatus =
  | { kind: 'none'; reason?: string }
  | { kind: 'detected'; project: IosProject }
  | {
      kind: 'ambiguous';
      candidates: Array<{
        projectPath: string;
        projectKind: IosProjectKind;
        schemes: string[];
      }>;
    }
  | { kind: 'error'; message: string };

export type IosDevice = {
  udid: string;
  name: string;
  runtime: string;
  state: string;
};

export type IosBuildRunOpts = {
  scheme?: string;
  udid: string;
  configuration?: 'Debug' | 'Release';
  bringForeground?: boolean;
};

export type IosBuildRunResult =
  | { ok: true; bundleId: string; pid: number; appPath: string; durationMs: number }
  | {
      ok: false;
      stage: 'detect' | 'build' | 'install' | 'launch';
      message: string;
      errors: string[];
    };

// xcodebuild errors look like:
//   /path/to/file.swift:42:13: error: cannot find 'foo' in scope
//   /path/to/file.swift:42:13: fatal error: …
//   ld: framework not found XYZ
//   xcodebuild: error: Scheme 'X' is not currently configured for the build action.
// The parser picks out distinct error lines and caps at 20 — full xcodebuild
// output can be megabytes and Claude is in a terminal, not a log aggregator.
export function parseBuildErrors(stdout: string): string[] {
  const lines = stdout.split('\n');
  const errors: string[] = [];
  const seen = new Set<string>();
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    let isError = false;
    if (/(^|:\s)(error:|fatal error:)/i.test(line)) isError = true;
    else if (/^ld: /.test(line)) isError = true;
    else if (/^(fatal error|error):/i.test(line)) isError = true;
    if (!isError) continue;
    if (seen.has(line)) continue;
    seen.add(line);
    errors.push(line);
    if (errors.length >= 20) break;
  }
  return errors;
}

// `xcrun simctl list devices booted -j` returns a `{devices: {<runtime>: [...]}}`
// object. Walk every runtime and keep the booted entries. Tolerant of shape
// drift between Xcode versions.
export function parseSimctlListBooted(json: string): IosDevice[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return [];
  }
  if (!parsed || typeof parsed !== 'object') return [];
  const devicesField = (parsed as { devices?: unknown }).devices;
  if (!devicesField || typeof devicesField !== 'object') return [];
  const out: IosDevice[] = [];
  for (const [runtime, list] of Object.entries(devicesField as Record<string, unknown>)) {
    if (!Array.isArray(list)) continue;
    for (const d of list) {
      if (!d || typeof d !== 'object') continue;
      const dd = d as { state?: unknown; udid?: unknown; name?: unknown };
      if (dd.state === 'Booted' && typeof dd.udid === 'string') {
        out.push({
          udid: dd.udid,
          name: typeof dd.name === 'string' ? dd.name : '',
          runtime,
          state: 'Booted',
        });
      }
    }
  }
  return out;
}

type RunResult = {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  timedOut: boolean;
  durationMs: number;
};

// Validators for strings that flow into spawn args or `--predicate` strings.
// Apple's bundle id grammar is alphanum + dot + dash + underscore; UDIDs are
// hex+dash; target names *can* contain spaces. Reject anything else so we
// don't smuggle quotes, commas, or `OR …` into a destination spec or NSPredicate.
export function isSafeUdid(s: string): boolean {
  // hex+dash 16–64 chars AND at least one hex digit (rejects all-dash strings
  // like '--------' which the simple character class would otherwise allow).
  return /^[A-Fa-f0-9-]{16,64}$/.test(s) && /[A-Fa-f0-9]/.test(s);
}
export function isSafeBundleId(s: string): boolean {
  return /^[A-Za-z0-9._-]{1,255}$/.test(s);
}
export function isSafeTargetName(s: string): boolean {
  return /^[A-Za-z0-9 ._-]{1,255}$/.test(s);
}

// Pure: pick a built `.app` filename by exact-match against a scheme, falling
// back to the first .app if nothing matches. Extracted from `findBuiltApp` so
// the selection priority is unit-testable without spawning PlistBuddy.
export function pickAppByScheme(apps: string[], scheme: string): string | null {
  if (apps.length === 0) return null;
  return apps.find((e) => e === `${scheme}.app`) ?? apps[0];
}

async function runCommand(
  cmd: string,
  args: string[],
  opts: { cwd?: string; timeoutMs?: number; detached?: boolean } = {},
): Promise<RunResult> {
  const start = Date.now();
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      stdio: ['ignore', 'pipe', 'pipe'],
      // `detached: true` puts the child in its own process group, which lets
      // us SIGKILL the whole subtree on timeout — important for xcodebuild,
      // which forks swift-frontend / clang / ld children that would otherwise
      // outlive the parent kill.
      detached: opts.detached ?? false,
    });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    if (opts.timeoutMs) {
      timer = setTimeout(() => {
        timedOut = true;
        if (opts.detached && typeof child.pid === 'number') {
          // Negative pid → process group. Best-effort; the child may have
          // already exited between timer fire and signal delivery.
          try {
            process.kill(-child.pid, 'SIGKILL');
          } catch {
            /* already dead */
          }
        } else {
          child.kill('SIGKILL');
        }
      }, opts.timeoutMs);
    }
    child.stdout?.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8');
    });
    child.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
    });
    child.on('error', (err) => {
      if (timer) clearTimeout(timer);
      // Surface spawn errors as a non-zero exit so callers don't need a
      // catch — spawn() rejects only for synchronous failures, and even
      // ENOENT shows up via the 'error' event after the promise resolves.
      resolve({
        stdout,
        stderr: stderr || (err instanceof Error ? err.message : String(err)),
        exitCode: -1,
        signal: null,
        timedOut,
        durationMs: Date.now() - start,
      });
    });
    child.on('close', (code, signal) => {
      if (timer) clearTimeout(timer);
      resolve({
        stdout,
        stderr,
        exitCode: code,
        signal,
        timedOut,
        durationMs: Date.now() - start,
      });
    });
  });
}

type ProjectLoc = { projectPath: string; projectKind: IosProjectKind };

const SKIP_DIRS = new Set([
  'node_modules',
  'Pods',
  '.build',
  'DerivedData',
  '.tango',
  '.git',
  'build',
]);

async function findXcodeCandidates(
  workspace: string,
  maxDepth = 3,
): Promise<ProjectLoc[]> {
  const out: ProjectLoc[] = [];
  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > maxDepth) return;
    let entries: Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    const subWalks: Promise<void>[] = [];
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (e.name.endsWith('.xcworkspace')) {
        out.push({
          projectPath: path.join(dir, e.name),
          projectKind: 'workspace',
        });
        continue;
      }
      if (e.name.endsWith('.xcodeproj')) {
        out.push({
          projectPath: path.join(dir, e.name),
          projectKind: 'project',
        });
        continue;
      }
      if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue;
      subWalks.push(walk(path.join(dir, e.name), depth + 1));
    }
    await Promise.all(subWalks);
  }
  await walk(workspace, 0);
  return out;
}

function preferWorkspaceOverProject(candidates: ProjectLoc[]): ProjectLoc[] {
  const byStem = new Map<string, ProjectLoc>();
  for (const c of candidates) {
    const stem = path
      .basename(c.projectPath)
      .replace(/\.(xcworkspace|xcodeproj)$/, '');
    const existing = byStem.get(stem);
    if (
      !existing ||
      (c.projectKind === 'workspace' && existing.projectKind === 'project')
    ) {
      byStem.set(stem, c);
    }
  }
  return Array.from(byStem.values());
}

async function listSchemesAndConfigs(
  c: ProjectLoc,
): Promise<
  | { ok: true; schemes: string[]; configurations: string[] }
  | { ok: false; message: string }
> {
  const flag = c.projectKind === 'workspace' ? '-workspace' : '-project';
  const r = await runCommand(
    'xcodebuild',
    ['-list', '-json', flag, c.projectPath],
    { timeoutMs: 30_000 },
  );
  if (r.exitCode !== 0) {
    const errText = (r.stderr || r.stdout).trim();
    // ENOENT on a vanilla machine is the most common first-run failure —
    // surface the canonical fix verbatim so the message Claude sees has the
    // command, not just the symptom.
    if (/ENOENT|not found|no such file or directory/i.test(errText)) {
      return {
        ok: false,
        message:
          'xcodebuild not found — install the Xcode Command Line Tools with `xcode-select --install`',
      };
    }
    const err = errText.slice(0, 200) || 'unknown error';
    return { ok: false, message: `xcodebuild -list failed: ${err}` };
  }
  try {
    const parsed = JSON.parse(r.stdout) as {
      workspace?: { schemes?: string[] };
      project?: { schemes?: string[]; configurations?: string[] };
    };
    if (c.projectKind === 'workspace') {
      return {
        ok: true,
        schemes: parsed.workspace?.schemes ?? [],
        // Workspace -list doesn't expose configurations; assume the standard pair.
        configurations: ['Debug', 'Release'],
      };
    }
    return {
      ok: true,
      schemes: parsed.project?.schemes ?? [],
      configurations: parsed.project?.configurations ?? ['Debug', 'Release'],
    };
  } catch {
    return { ok: false, message: 'xcodebuild -list returned non-JSON output' };
  }
}

// `xcodebuild -showBuildSettings` text output format:
//   Build settings for action build and target tangotestswift:
//       PRODUCT_BUNDLE_IDENTIFIER = com.heyadam.tangotestswift
//       …
async function getBundleIdentifier(
  c: ProjectLoc,
  scheme: string,
): Promise<string | null> {
  const flag = c.projectKind === 'workspace' ? '-workspace' : '-project';
  const r = await runCommand(
    'xcodebuild',
    [
      '-showBuildSettings',
      flag,
      c.projectPath,
      '-scheme',
      scheme,
      '-configuration',
      'Debug',
    ],
    { timeoutMs: 60_000 },
  );
  if (r.exitCode !== 0) return null;
  const m = r.stdout.match(/^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)/m);
  return m ? m[1].trim() : null;
}

export async function detectXcodeProject(
  workspace: string,
): Promise<IosProjectStatus> {
  if (process.platform !== 'darwin') {
    return { kind: 'none', reason: 'iOS toolchain only on macOS' };
  }

  let candidates: ProjectLoc[];
  try {
    candidates = await findXcodeCandidates(workspace);
  } catch (err) {
    return {
      kind: 'error',
      message:
        'failed to scan workspace for Xcode projects: ' +
        (err instanceof Error ? err.message : String(err)),
    };
  }

  if (candidates.length === 0) {
    return { kind: 'none' };
  }

  candidates = preferWorkspaceOverProject(candidates);
  const folderName = path.basename(workspace);

  // If there's only one candidate, or one matches the workspace folder name,
  // resolve it fully (schemes + bundle id).
  let pick: ProjectLoc | null = null;
  if (candidates.length === 1) {
    pick = candidates[0];
  } else {
    pick =
      candidates.find(
        (c) =>
          path
            .basename(c.projectPath)
            .replace(/\.(xcworkspace|xcodeproj)$/, '') === folderName,
      ) ?? null;
  }

  if (pick) {
    const info = await listSchemesAndConfigs(pick);
    if (!info.ok) return { kind: 'error', message: info.message };
    if (info.schemes.length === 0) {
      return {
        kind: 'error',
        message: `no schemes found in ${path.basename(pick.projectPath)}`,
      };
    }
    // Prefer scheme matching the folder name; otherwise the first one.
    const scheme =
      info.schemes.find((s) => s === folderName) ?? info.schemes[0];
    const bundleId = await getBundleIdentifier(pick, scheme).catch(() => null);
    return {
      kind: 'detected',
      project: {
        projectPath: pick.projectPath,
        projectKind: pick.projectKind,
        scheme,
        bundleId,
        configurations: info.configurations,
      },
    };
  }

  // Multiple candidates, none matching by name — let Claude pick via ios_status.
  const annotated: Array<{
    projectPath: string;
    projectKind: IosProjectKind;
    schemes: string[];
  }> = [];
  for (const c of candidates) {
    const info = await listSchemesAndConfigs(c);
    annotated.push({ ...c, schemes: info.ok ? info.schemes : [] });
  }
  return { kind: 'ambiguous', candidates: annotated };
}

export async function listBootedDevices(): Promise<IosDevice[]> {
  if (process.platform !== 'darwin') return [];
  const r = await runCommand(
    'xcrun',
    ['simctl', 'list', 'devices', 'booted', '-j'],
    { timeoutMs: 10_000 },
  );
  if (r.exitCode !== 0) return [];
  return parseSimctlListBooted(r.stdout);
}

// serve-sim's `/.sim/api` returns `{pid, port, device, url, streamUrl, wsUrl}`.
// `device` is the booted simulator UDID it's currently streaming. Use it to
// align builds with whatever the iframe is showing — important when the user
// has multiple simulators booted.
export async function readActiveDeviceFromServeSim(
  serveSimUrl: string,
): Promise<string | null> {
  try {
    const res = await fetch(`${serveSimUrl}/.sim/api`, {
      signal: AbortSignal.timeout(2_000),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { device?: unknown };
    return typeof data?.device === 'string' && data.device.length > 0
      ? data.device
      : null;
  } catch {
    return null;
  }
}

async function isHostAppBundle(appPath: string): Promise<boolean> {
  // CFBundlePackageType is 'APPL' for full host apps, 'XPC!' for extensions,
  // 'FMWK' for frameworks, 'BNDL' for loadable bundles. Only APPL is what
  // simctl install/launch wants.
  const r = await runCommand(
    '/usr/libexec/PlistBuddy',
    ['-c', 'Print CFBundlePackageType', path.join(appPath, 'Info.plist')],
    { timeoutMs: 5_000 },
  );
  return r.exitCode === 0 && r.stdout.trim() === 'APPL';
}

// `entries.find(e => e.endsWith('.app'))` picks an arbitrary app from the
// products dir, which is wrong when the project has extension / watch /
// widget targets sitting alongside the host app. Match the scheme's exact
// `<scheme>.app` first; if that misses (PRODUCT_NAME override on the host
// target), fall back to the first .app whose Info.plist has
// CFBundlePackageType == APPL. Returns null if no host app exists in the
// products dir.
async function findBuiltApp(
  derivedData: string,
  configuration: string,
  scheme: string,
): Promise<string | null> {
  const productsDir = path.join(
    derivedData,
    'Build',
    'Products',
    `${configuration}-iphonesimulator`,
  );
  let entries: string[];
  try {
    entries = await fs.readdir(productsDir);
  } catch {
    return null;
  }
  const apps = entries.filter((e) => e.endsWith('.app'));
  if (apps.length === 0) return null;
  const exact = apps.find((e) => e === `${scheme}.app`);
  if (exact) return path.join(productsDir, exact);
  for (const a of apps) {
    const candidate = path.join(productsDir, a);
    if (await isHostAppBundle(candidate)) return candidate;
  }
  return null;
}

async function readBundleIdFromAppBundle(
  appPath: string,
): Promise<string | null> {
  const r = await runCommand(
    '/usr/libexec/PlistBuddy',
    ['-c', 'Print CFBundleIdentifier', path.join(appPath, 'Info.plist')],
    { timeoutMs: 5_000 },
  );
  if (r.exitCode !== 0) return null;
  const id = r.stdout.trim();
  return id ? id : null;
}

async function ensureTangoDir(workspace: string): Promise<void> {
  const dir = path.join(workspace, '.tango');
  await fs.mkdir(dir, { recursive: true });
  // Keep the build cache out of the user's git diff. Best-effort — don't
  // override an existing `.gitignore` they might have customized.
  const gi = path.join(dir, '.gitignore');
  try {
    await fs.access(gi);
  } catch {
    await fs.writeFile(gi, '*\n').catch(() => {});
  }
}

export async function iosBuildRun(
  workspace: string,
  project: IosProject,
  opts: IosBuildRunOpts,
): Promise<IosBuildRunResult> {
  const start = Date.now();

  // The whole iOS toolchain is darwin-only. Without this gate, `xcodebuild`
  // would just resolve to ENOENT on every other platform and the user would
  // see a confusing "exited with code -1" message instead of a clear "wrong
  // OS." Mirrors the gate at the top of `iosLogsRecent`.
  if (process.platform !== 'darwin') {
    return {
      ok: false,
      stage: 'detect',
      message: 'iOS toolchain only available on macOS',
      errors: [],
    };
  }

  const scheme = opts.scheme ?? project.scheme;
  const configuration = opts.configuration ?? 'Debug';
  const udid = opts.udid;
  const bringForeground = opts.bringForeground ?? true;
  const derivedData = path.join(workspace, '.tango', 'DerivedData');

  // Reject malformed udids before they reach -destination. Real simulator
  // udids are hex+dash; anything else is either a bug in the caller or an
  // attempt to smuggle additional destination specifiers.
  if (!isSafeUdid(udid)) {
    return {
      ok: false,
      stage: 'detect',
      message: `udid is not a valid simulator identifier: ${udid.slice(0, 64)}`,
      errors: [],
    };
  }

  try {
    await ensureTangoDir(workspace);
  } catch (err) {
    return {
      ok: false,
      stage: 'build',
      message: `failed to prepare .tango directory: ${err instanceof Error ? err.message : String(err)}`,
      errors: [],
    };
  }

  const flag = project.projectKind === 'workspace' ? '-workspace' : '-project';
  const buildResult = await runCommand(
    'xcodebuild',
    [
      flag,
      project.projectPath,
      '-scheme',
      scheme,
      '-configuration',
      configuration,
      '-destination',
      `platform=iOS Simulator,id=${udid}`,
      '-derivedDataPath',
      derivedData,
      'build',
    ],
    { cwd: workspace, timeoutMs: 5 * 60_000, detached: true },
  );

  if (buildResult.exitCode !== 0) {
    const errors = parseBuildErrors(buildResult.stdout + '\n' + buildResult.stderr);
    const msg = buildResult.timedOut
      ? `xcodebuild timed out after ${(buildResult.durationMs / 1000).toFixed(0)}s`
      : `xcodebuild exited with code ${buildResult.exitCode}`;
    return { ok: false, stage: 'build', message: msg, errors };
  }

  const appPath = await findBuiltApp(derivedData, configuration, scheme);
  if (!appPath) {
    return {
      ok: false,
      stage: 'build',
      message: `built .app not found in ${path.join(derivedData, 'Build/Products', `${configuration}-iphonesimulator`)}`,
      errors: [],
    };
  }

  let bundleId = project.bundleId;
  if (!bundleId) {
    bundleId = await readBundleIdFromAppBundle(appPath);
  }
  if (!bundleId) {
    return {
      ok: false,
      stage: 'install',
      message:
        'could not determine bundle id (PRODUCT_BUNDLE_IDENTIFIER) from project or built .app',
      errors: [],
    };
  }

  const installResult = await runCommand(
    'xcrun',
    ['simctl', 'install', udid, appPath],
    { timeoutMs: 30_000 },
  );
  if (installResult.exitCode !== 0) {
    return {
      ok: false,
      stage: 'install',
      message: (installResult.stderr || installResult.stdout).trim().slice(0, 500),
      errors: [],
    };
  }

  if (bringForeground) {
    // Best-effort terminate so the running instance restarts with the new bundle.
    // Ignore "not running" / "no matching process" errors.
    await runCommand(
      'xcrun',
      ['simctl', 'terminate', udid, bundleId],
      { timeoutMs: 10_000 },
    );
  }

  const launchResult = await runCommand(
    'xcrun',
    ['simctl', 'launch', udid, bundleId],
    { timeoutMs: 30_000 },
  );
  if (launchResult.exitCode !== 0) {
    return {
      ok: false,
      stage: 'launch',
      message: (launchResult.stderr || launchResult.stdout).trim().slice(0, 500),
      errors: [],
    };
  }
  // simctl launch output looks like: "com.example.app: 12345"
  const pidMatch = launchResult.stdout.match(/:\s*(\d+)/);
  const pid = pidMatch ? parseInt(pidMatch[1], 10) : 0;

  return {
    ok: true,
    bundleId,
    pid,
    appPath,
    durationMs: Date.now() - start,
  };
}

export type IosLogEntry = {
  ts?: string;
  level?: string;
  message: string;
};

// `rejected` is set when an input failed validation (and we never spawned
// simctl). Distinguishes "no log entries in the window" from "we refused to
// run the query" — without it, `entries: []` is ambiguous and Claude can't
// tell whether to retry with a wider window or fix the inputs.
export type IosLogsResult = {
  entries: IosLogEntry[];
  truncated: boolean;
  rejected?: 'platform-unsupported' | 'invalid-udid' | 'invalid-bundle-id';
};

// `xcrun simctl spawn <udid> log show` is the canonical way to read what the
// simulated device wrote to unified logging. We don't subscribe to serve-sim's
// /.sim/logs SSE — that's a single-consumer stream the iframe is already on,
// and spawning our own `log show` is independent.
//
// The predicate matches both `subsystem == bundleId` (modern os.log apps) and
// `processImagePath CONTAINS targetName` (process-name match for stdout/stderr
// noise) so SwiftUI apps that haven't adopted os.log still produce signal.
export async function iosLogsRecent(opts: {
  udid: string;
  bundleId: string;
  appPath?: string | null;
  sinceSeconds?: number;
  maxEntries?: number;
}): Promise<IosLogsResult> {
  if (process.platform !== 'darwin') {
    return { entries: [], truncated: false, rejected: 'platform-unsupported' };
  }
  if (!isSafeUdid(opts.udid)) {
    return { entries: [], truncated: false, rejected: 'invalid-udid' };
  }
  // Both predicates and -destination strings are vulnerable to grammar
  // smuggling via embedded quotes. Reject malformed bundleIds outright; for
  // targetName, fall back to a bundle-id-only predicate if it's unsafe (the
  // common reason it'd be unsafe is a target-bundle-name mismatch we don't
  // need to second-guess).
  if (!isSafeBundleId(opts.bundleId)) {
    return { entries: [], truncated: false, rejected: 'invalid-bundle-id' };
  }
  const sinceSeconds = opts.sinceSeconds ?? 30;
  const maxEntries = opts.maxEntries ?? 500;
  const rawTargetName = opts.appPath
    ? path.basename(opts.appPath).replace(/\.app$/, '')
    : (opts.bundleId.split('.').pop() ?? opts.bundleId);
  const safeTarget = isSafeTargetName(rawTargetName) ? rawTargetName : null;

  const predicate = safeTarget
    ? `subsystem == "${opts.bundleId}" OR processImagePath CONTAINS "${safeTarget}"`
    : `subsystem == "${opts.bundleId}"`;

  const r = await runCommand(
    'xcrun',
    [
      'simctl',
      'spawn',
      opts.udid,
      'log',
      'show',
      '--predicate',
      predicate,
      '--last',
      `${sinceSeconds}s`,
      '--style',
      'ndjson',
    ],
    { timeoutMs: 15_000 },
  );
  if (r.exitCode !== 0) return { entries: [], truncated: false };

  const lines = r.stdout.split('\n').filter(Boolean);
  const entries: IosLogEntry[] = [];
  let truncated = false;
  for (const line of lines) {
    if (entries.length >= maxEntries) {
      truncated = true;
      break;
    }
    try {
      const obj = JSON.parse(line) as {
        timestamp?: string;
        messageType?: string;
        eventMessage?: string;
      };
      if (typeof obj.eventMessage !== 'string') continue;
      entries.push({
        ts: obj.timestamp,
        level: obj.messageType,
        message: obj.eventMessage,
      });
    } catch {
      // skip non-JSON header / footer lines
    }
  }
  return { entries, truncated };
}
