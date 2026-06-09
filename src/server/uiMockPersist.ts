// Write-behind durability for the design spec: `<workspace>/.tango/design.json`.
//
// The in-memory cache in uiMockBridge stays runtime-authoritative; this module
// only persists it (debounced) and hydrates it back at boot / workspace
// switch. Nothing reads the file at request time. The file is committable —
// ensureWorkspace writes a targeted .tango/.gitignore so build junk stays
// ignored while design.json is tracked.
//
// Race-freedom across workspace switches: schedulePersist captures
// (workspace, spec) at schedule time and keys pending writes by workspace, so
// a pending write for the old workspace always writes the old workspace's
// last spec — never the new (already-reset) cache, and never the wrong file.

import { promises as fs } from 'node:fs';
import { writeFileSync, mkdirSync, renameSync } from 'node:fs';
import path from 'node:path';
import { atomicWrite } from './fsAtomic';
import { uiSpecSchema } from '@/lib/uiMockSchema';
import type { UISpec } from '@/lib/uiMockProtocol';

const FILE_VERSION = 1;
const PERSIST_DEBOUNCE_MS = 750;

export function designJsonPath(workspace: string): string {
  return path.join(workspace, '.tango', 'design.json');
}

// Pure. Versioned envelope, 2-space indent, trailing newline — stable output
// for a given spec (savedAt aside) so git diffs stay readable.
export function serializeSpecFile(spec: UISpec, savedAt: string): string {
  return (
    JSON.stringify({ version: FILE_VERSION, savedAt, spec }, null, 2) + '\n'
  );
}

// Pure. Returns null for anything that isn't a valid v1 envelope carrying a
// schema-valid spec — callers treat null as "no usable file".
export function parseSpecFile(raw: string): UISpec | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  const envelope = parsed as { version?: unknown; spec?: unknown };
  if (envelope.version !== FILE_VERSION) return null;
  const result = uiSpecSchema.safeParse(envelope.spec);
  return result.success ? (result.data as UISpec) : null;
}

// ── debounced write-behind ────────────────────────────────────────────────

type Pending = {
  spec: UISpec;
  timer: ReturnType<typeof setTimeout>;
};

// Keyed by workspace path: a switch mid-debounce leaves the old workspace's
// pending write untouched — it fires with its own captured spec.
const pending = new Map<string, Pending>();

// Serial write chain so concurrent fires can't interleave on one file, and
// tests can await all outstanding writes.
let writeChain: Promise<void> = Promise.resolve();

function enqueueWrite(workspace: string, spec: UISpec): void {
  writeChain = writeChain
    .then(() => writeSpecFile(workspace, spec))
    .catch((err) => {
      console.warn(
        '[design] failed to persist design.json:',
        err instanceof Error ? err.message : String(err),
      );
    });
}

async function writeSpecFile(workspace: string, spec: UISpec): Promise<void> {
  const dest = designJsonPath(workspace);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await atomicWrite(dest, serializeSpecFile(spec, new Date().toISOString()));
}

export function schedulePersist(workspace: string, spec: UISpec): void {
  const existing = pending.get(workspace);
  if (existing) clearTimeout(existing.timer);
  const timer = setTimeout(() => {
    const job = pending.get(workspace);
    pending.delete(workspace);
    if (job) enqueueWrite(workspace, job.spec);
  }, PERSIST_DEBOUNCE_MS);
  // Don't hold the event loop open for a debounce timer.
  timer.unref?.();
  pending.set(workspace, { spec, timer });
}

// Fire all pending writes now (async). Called on workspace switch so the old
// workspace's last sub-debounce edits aren't dropped.
export function flushPendingPersist(): void {
  for (const [workspace, job] of pending) {
    clearTimeout(job.timer);
    enqueueWrite(workspace, job.spec);
  }
  pending.clear();
}

// Sync variant for process 'exit' (which can't await): a Ctrl-C mid-debounce
// still lands the last edit on disk. Plain writeFileSync — atomicity matters
// less than existence here, and rename-based atomic needs two syscalls anyway.
export function flushPersistSync(): void {
  for (const [workspace, job] of pending) {
    clearTimeout(job.timer);
    try {
      const dest = designJsonPath(workspace);
      mkdirSync(path.dirname(dest), { recursive: true });
      writeFileSync(dest, serializeSpecFile(job.spec, new Date().toISOString()));
    } catch {
      /* exiting — nothing else to do */
    }
  }
  pending.clear();
}

export async function loadSpecFromDisk(
  workspace: string,
): Promise<UISpec | null> {
  const p = designJsonPath(workspace);
  let raw: string;
  try {
    raw = await fs.readFile(p, 'utf8');
  } catch {
    return null; // no file yet
  }
  const spec = parseSpecFile(raw);
  if (spec == null) {
    // Never destroy: rescue the unreadable file aside so the user (or agent)
    // can inspect it, then start fresh. Mirrors memory.ts's policy.
    try {
      renameSync(p, path.join(path.dirname(p), `design.invalid-${Date.now()}.json`));
    } catch {
      /* best effort */
    }
    return null;
  }
  return spec;
}

/** @internal exported for tests — await all outstanding (already-fired) writes. */
export function _writesSettled(): Promise<void> {
  return writeChain;
}

/** @internal exported for tests — drop pending timers without writing. */
export function _resetForTests(): void {
  for (const [, job] of pending) clearTimeout(job.timer);
  pending.clear();
}
