// Lifecycle for the preview-host app: build (once per machine, cached derived
// data), install, and launch it on the booted simulator. After launch the app
// connects back to /ws/preview on its own; canvas edits then stream to the
// simulator with no rebuild — xcodebuild only re-enters the picture on
// "Export & Run".
//
// The Xcode project lives in the tango REPO (preview-host/), not the user's
// workspace — found via TANGO_REPO_ROOT (set in server.ts). Derived data goes
// to ~/.tango/preview-host-build: user-level, workspace-independent, so the
// cold ~30–60s build happens once per machine/Xcode version and warm rebuilds
// are a 2–4s no-op.

import os from 'node:os';
import path from 'node:path';
import { isSafeUdid, runCommand } from './iosBuild';
import { resolveActiveUdid } from './iosBuild';
import { getHook } from './serverHooks';
import { tangoPort, tangoRepoRoot } from './config';

export const PREVIEW_BUNDLE_ID = 'dev.tango.preview-host';

export type PreviewHostStatus =
  | { phase: 'stopped' }
  | { phase: 'building'; startedAt: number }
  | { phase: 'installing' }
  | { phase: 'launching' }
  | { phase: 'running'; udid: string; pid: number | null }
  | { phase: 'error'; message: string };

type PreviewHostSlot = { status: PreviewHostStatus };

const SLOT_KEY = '__tangoPreviewHostSlot__';

function getSlot(): PreviewHostSlot {
  const g = globalThis as typeof globalThis & { [SLOT_KEY]?: PreviewHostSlot };
  if (!g[SLOT_KEY]) g[SLOT_KEY] = { status: { phase: 'stopped' } };
  return g[SLOT_KEY];
}

export function getPreviewHostStatus(): PreviewHostStatus & {
  connected: boolean;
} {
  const connected = (getHook('previewClientCount')?.() ?? 0) > 0;
  return { ...getSlot().status, connected };
}

function isBusy(status: PreviewHostStatus): boolean {
  return (
    status.phase === 'building' ||
    status.phase === 'installing' ||
    status.phase === 'launching'
  );
}

export function isPreviewHostBusy(): boolean {
  return isBusy(getSlot().status);
}

function fail(message: string): PreviewHostStatus {
  const status: PreviewHostStatus = { phase: 'error', message };
  getSlot().status = status;
  return status;
}

function repoRoot(): string | null {
  return tangoRepoRoot();
}

function derivedDataPath(): string {
  return path.join(os.homedir(), '.tango', 'preview-host-build');
}

// Idempotent: when the app is already running AND a /ws/preview client is
// connected, this just brings it to the foreground — Export & Run launches
// the user's app over it, so "Preview" must reclaim the screen, not no-op.
// When it's running but disconnected (user killed the app), the install is
// still present, so the relaunch path is fast.
export async function startPreviewHost(opts?: {
  udid?: string;
}): Promise<PreviewHostStatus> {
  const slot = getSlot();
  if (isBusy(slot.status)) return slot.status;

  if (process.platform !== 'darwin') {
    return fail('the iOS preview host requires macOS');
  }
  const root = repoRoot();
  if (!root) {
    return fail('TANGO_REPO_ROOT is not set — run tango via its custom server');
  }
  if (opts?.udid !== undefined && !isSafeUdid(opts.udid)) {
    return fail(`udid is not a valid simulator identifier: ${opts.udid.slice(0, 64)}`);
  }

  const udid = await resolveActiveUdid(opts?.udid);
  if (!udid) {
    return fail(
      'no booted iOS simulator (boot one from Xcode → Open Developer Tool → Simulator)',
    );
  }

  // Fast path: app alive, socket attached, same simulator — it may still be
  // backgrounded (e.g. export_run just foregrounded the exported app), so
  // foreground it. `simctl launch` on an already-running process does not
  // restart it (same pid comes back); it only activates it. If the launch
  // fails (device rebooted, app uninstalled), fall through to the full
  // build/install/launch path.
  const connected = (getHook('previewClientCount')?.() ?? 0) > 0;
  if (slot.status.phase === 'running' && connected && slot.status.udid === udid) {
    const fg = await runCommand(
      'xcrun',
      ['simctl', 'launch', udid, PREVIEW_BUNDLE_ID],
      { timeoutMs: 15_000 },
    );
    if (fg.exitCode === 0) return slot.status;
  }

  // Build. Incremental no-op when warm; ~30–60s once per machine when cold.
  slot.status = { phase: 'building', startedAt: Date.now() };
  const projectPath = path.join(root, 'preview-host', 'PreviewHost.xcodeproj');
  const dd = derivedDataPath();
  const build = await runCommand(
    'xcodebuild',
    [
      '-project',
      projectPath,
      '-scheme',
      'PreviewHost',
      '-configuration',
      'Debug',
      '-destination',
      `platform=iOS Simulator,id=${udid}`,
      '-derivedDataPath',
      dd,
      'CODE_SIGNING_ALLOWED=NO',
      'CODE_SIGNING_REQUIRED=NO',
      'build',
    ],
    { timeoutMs: 5 * 60_000, detached: true },
  );
  if (build.exitCode !== 0) {
    const tail = (build.stderr || build.stdout).split('\n').slice(-6).join('\n');
    return fail(`preview host build failed: ${tail.trim() || 'unknown error'}`);
  }

  const appPath = path.join(
    dd,
    'Build',
    'Products',
    'Debug-iphonesimulator',
    'PreviewHost.app',
  );

  slot.status = { phase: 'installing' };
  const install = await runCommand(
    'xcrun',
    ['simctl', 'install', udid, appPath],
    { timeoutMs: 60_000 },
  );
  if (install.exitCode !== 0) {
    return fail(`simctl install failed: ${install.stderr.trim()}`);
  }

  // Relaunch with the current port: terminate first (ignore "not running").
  await runCommand('xcrun', ['simctl', 'terminate', udid, PREVIEW_BUNDLE_ID], {
    timeoutMs: 15_000,
  });

  slot.status = { phase: 'launching' };
  const port = String(tangoPort());
  const launch = await runCommand(
    'xcrun',
    ['simctl', 'launch', udid, PREVIEW_BUNDLE_ID],
    {
      timeoutMs: 30_000,
      // simctl forwards SIMCTL_CHILD_* (prefix stripped) into the launched
      // process — this is how the app learns which port tango listens on.
      env: { SIMCTL_CHILD_TANGO_WS_PORT: port },
    },
  );
  if (launch.exitCode !== 0) {
    return fail(`simctl launch failed: ${launch.stderr.trim()}`);
  }

  // Output shape: "dev.tango.preview-host: 12345"
  const pidMatch = /:\s*(\d+)\s*$/.exec(launch.stdout.trim());
  const status: PreviewHostStatus = {
    phase: 'running',
    udid,
    pid: pidMatch ? Number(pidMatch[1]) : null,
  };
  slot.status = status;
  return status;
}
