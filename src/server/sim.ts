import { spawn, type ChildProcess } from 'node:child_process';

export type SimStatus =
  | { phase: 'unsupported' }
  | { phase: 'starting' }
  | { phase: 'ready'; url: string }
  | { phase: 'error'; message: string };

// Singleton state. Stashed on `globalThis` because Next.js loads route
// handlers in a different module graph from the custom server (server.ts).
// Without this, `getSimStatus()` inside /api/sim/status would always read
// its module-default ({phase:'unsupported'}) even after server boot has
// successfully spawned the helper. Mirrors the workspace.ts slot pattern.
type SimSlot = {
  state: SimStatus;
  child: ChildProcess | null;
  killTimer: ReturnType<typeof setTimeout> | null;
};

const SLOT_KEY = '__tangoSimSlot__';

function getSlot(): SimSlot {
  const g = globalThis as typeof globalThis & { [SLOT_KEY]?: SimSlot };
  if (!g[SLOT_KEY]) {
    g[SLOT_KEY] = {
      state: { phase: 'unsupported' },
      child: null,
      killTimer: null,
    };
  }
  return g[SLOT_KEY];
}

// serve-sim prints `  - Local:   http://localhost:3200` on the line where
// its preview server comes up (followed by an optional `  - Network: …`).
// Don't be fooled by the README's `# → Preview at …` example — that string
// is documentation, not actual stdout.
const PREVIEW_RE = /Local:\s+(https?:\/\/\S+)\s/;
const ALLOWED_HOSTS = new Set(['localhost', '127.0.0.1', '::1']);

export function parsePreviewUrl(text: string): string | null {
  const m = text.match(PREVIEW_RE);
  if (!m) return null;
  let parsed: URL;
  try {
    parsed = new URL(m[1].trim());
  } catch {
    return null;
  }
  // Defense-in-depth: never iframe a URL the helper printed if it's not local.
  // A compromised serve-sim could otherwise redirect us anywhere.
  const host = parsed.hostname.replace(/^\[|\]$/g, '');
  if (!ALLOWED_HOSTS.has(host)) return null;
  return parsed.toString().replace(/\/$/, '');
}

function killGroup(proc: ChildProcess, signal: NodeJS.Signals): void {
  const pid = proc.pid;
  try {
    if (pid != null) {
      // Negative pid = process group. Requires `detached: true` at spawn so the
      // child has its own group; without that, we'd be signalling our own group.
      process.kill(-pid, signal);
    } else {
      proc.kill(signal);
    }
  } catch {
    // already dead, or wrong permissions — best-effort
  }
}

export function startSimHelper(): void {
  const slot = getSlot();

  if (process.platform !== 'darwin') {
    slot.state = { phase: 'unsupported' };
    return;
  }
  if (slot.child) return;

  slot.state = { phase: 'starting' };

  let proc: ChildProcess;
  try {
    proc = spawn('npx', ['serve-sim'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
  } catch (err) {
    slot.state = {
      phase: 'error',
      message: err instanceof Error ? err.message : 'failed to spawn serve-sim',
    };
    return;
  }

  slot.child = proc;

  let stdoutBuf = '';
  let stderrBuf = '';

  proc.stdout?.on('data', (chunk: Buffer) => {
    if (slot.state.phase === 'ready') return;
    stdoutBuf += chunk.toString('utf8');
    if (stdoutBuf.length > 8192) stdoutBuf = stdoutBuf.slice(-8192);
    const url = parsePreviewUrl(stdoutBuf);
    if (url) {
      slot.state = { phase: 'ready', url };
      stdoutBuf = '';
      console.log(`tango: simulator helper ready at ${url}`);
    }
  });

  proc.stderr?.on('data', (chunk: Buffer) => {
    stderrBuf += chunk.toString('utf8');
    if (stderrBuf.length > 4096) stderrBuf = stderrBuf.slice(-4096);
  });

  proc.on('error', (err) => {
    if (slot.child === proc) slot.child = null;
    const message = /ENOENT/.test(err.message)
      ? 'npx not found on PATH — install Node.js to use the simulator panel'
      : err.message;
    slot.state = { phase: 'error', message };
  });

  proc.on('exit', (code, signal) => {
    if (slot.child === proc) slot.child = null;
    if (slot.state.phase === 'ready') {
      slot.state = {
        phase: 'error',
        message: `serve-sim exited (code=${code ?? 'null'}, signal=${signal ?? 'null'})`,
      };
    } else if (slot.state.phase === 'starting') {
      const tail = stderrBuf.trim();
      slot.state = {
        phase: 'error',
        message:
          tail ||
          `serve-sim exited before ready (code=${code ?? 'null'}, signal=${signal ?? 'null'})`,
      };
    }
  });
}

export function stopSimHelper(): void {
  const slot = getSlot();
  const proc = slot.child;
  if (!proc) return;
  slot.child = null;
  if (slot.killTimer) {
    clearTimeout(slot.killTimer);
    slot.killTimer = null;
  }
  killGroup(proc, 'SIGTERM');
  const t = setTimeout(() => {
    slot.killTimer = null;
    if (proc.exitCode == null && proc.signalCode == null) {
      killGroup(proc, 'SIGKILL');
    }
  }, 2000);
  t.unref?.();
  slot.killTimer = t;
}

export function getSimStatus(): SimStatus {
  return getSlot().state;
}
