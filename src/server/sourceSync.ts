// Screen↔source sync watcher: watches the workspace's Swift sources and
// recomputes per-screen sync statuses ('synced' | 'stale' | 'missing') by
// comparing each linked screen's `sourceHash` (stamped at import) against the
// live file. Statuses broadcast over /ws/ui-mock as `source_sync` frames; the
// canvas renders them on the screen title-row chip.
//
// Lives in server.ts's module graph (it talks to uiMockBridge directly).
// Lifecycle: started at boot after spec hydration, re-pointed on workspace
// switch via the `sourceSyncRestart` hook. The watcher is best-effort — if
// fs.watch is unavailable or dies, statuses still refresh whenever screen
// provenance changes (the bridge pings us from cacheChanged).

import { promises as fs } from 'node:fs';
import { watch, type FSWatcher } from 'node:fs';
import path from 'node:path';
import {
  computeSyncStatuses,
  provenanceSignature,
} from './sourceHash';
import { getWorkspaceOrNull } from './workspace';
import {
  _setSourceSyncSpecListener,
  broadcastSourceSync,
  getUIMock,
} from './uiMockBridge';
import type { SourceSyncStatus } from '@/lib/uiMockProtocol';

// Directory segments that never hold user sources — mirror the import scan's
// skip list, plus TangoGenerated (exports are tango-owned; their churn during
// Export & Run must not trigger recompute storms).
const SKIP_SEGMENTS = new Set([
  'Pods',
  'DerivedData',
  'build',
  '.build',
  '.swiftpm',
  '.tango',
  '.git',
  'node_modules',
  'Preview Content',
  'TangoGenerated',
]);

const DEBOUNCE_MS = 300;

type SourceSyncSlot = {
  watcher: FSWatcher | null;
  workspace: string | null;
  debounce: ReturnType<typeof setTimeout> | null;
  signature: string;
  statuses: Record<string, SourceSyncStatus>;
};

const SLOT_KEY = '__tangoSourceSyncSlot__';

function getSlot(): SourceSyncSlot {
  const g = globalThis as typeof globalThis & { [SLOT_KEY]?: SourceSyncSlot };
  if (!g[SLOT_KEY]) {
    g[SLOT_KEY] = {
      watcher: null,
      workspace: null,
      debounce: null,
      signature: '',
      statuses: {},
    };
  }
  return g[SLOT_KEY];
}

function readWorkspaceFile(ws: string) {
  const root = path.resolve(ws);
  return async (rel: string): Promise<Buffer | null> => {
    const abs = path.resolve(root, rel);
    // Provenance paths come from the import allowlist, but never follow one
    // outside the workspace.
    if (abs !== root && !abs.startsWith(root + path.sep)) return null;
    try {
      return await fs.readFile(abs);
    } catch {
      return null;
    }
  };
}

// Recompute and broadcast when anything actually changed. `force` skips the
// provenance-signature short-circuit (file-change events leave the signature
// untouched but can flip statuses).
async function recompute(force: boolean): Promise<void> {
  const slot = getSlot();
  const ws = getWorkspaceOrNull();
  if (!ws) {
    if (Object.keys(slot.statuses).length > 0) {
      slot.statuses = {};
      broadcastSourceSync({});
    }
    return;
  }
  const spec = getUIMock();
  const sig = provenanceSignature(spec);
  if (!force && sig === slot.signature) return;
  slot.signature = sig;
  const statuses = await computeSyncStatuses(spec, readWorkspaceFile(ws));
  if (JSON.stringify(statuses) !== JSON.stringify(slot.statuses)) {
    slot.statuses = statuses;
    broadcastSourceSync(statuses);
  }
}

function scheduleRecompute(): void {
  const slot = getSlot();
  if (slot.debounce) clearTimeout(slot.debounce);
  const timer = setTimeout(() => {
    slot.debounce = null;
    void recompute(true);
  }, DEBOUNCE_MS);
  timer.unref?.();
  slot.debounce = timer;
}

function stopWatcher(): void {
  const slot = getSlot();
  if (slot.watcher) {
    try {
      slot.watcher.close();
    } catch {
      // already closed
    }
    slot.watcher = null;
  }
  if (slot.debounce) {
    clearTimeout(slot.debounce);
    slot.debounce = null;
  }
}

// Idempotent: points the watcher at the CURRENT workspace (reads it itself so
// the hook needs no argument). Safe to call at boot and on every switch.
export function startSourceSync(): void {
  const slot = getSlot();
  const ws = getWorkspaceOrNull();
  if (slot.workspace === ws && slot.watcher !== null) return;
  stopWatcher();
  slot.workspace = ws;
  slot.signature = '';
  slot.statuses = {};
  // The bridge pings on every cacheChanged; the signature short-circuit makes
  // the common case (geometry edits) free.
  _setSourceSyncSpecListener(() => void recompute(false));
  if (!ws) return;
  try {
    const watcher = watch(
      ws,
      { recursive: true, persistent: false },
      (_event, filename) => {
        if (!filename || !filename.endsWith('.swift')) return;
        const segments = filename.split(path.sep);
        if (segments.some((seg) => SKIP_SEGMENTS.has(seg))) return;
        scheduleRecompute();
      },
    );
    watcher.on('error', () => {
      // Watched root vanished (workspace deleted mid-session) — drop the
      // watcher; provenance-change recomputes keep working.
      stopWatcher();
    });
    slot.watcher = watcher;
  } catch {
    // fs.watch unavailable — degrade to provenance-change recomputes only.
  }
  void recompute(true);
}

/** Current statuses (attach-time replay lives in the bridge's copy; this is
 * for diagnostics/tests). */
export function getSourceSyncStatuses(): Record<string, SourceSyncStatus> {
  return getSlot().statuses;
}
