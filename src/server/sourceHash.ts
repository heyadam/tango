// Pure(ish) helpers behind screen↔source sync: content fingerprinting and
// per-screen status computation. Kept free of uiMockBridge imports so the
// fast-import engine (route-handler module graph) can stamp hashes without
// transitively loading the bridge — see the module-graph rule in CLAUDE.md.

import { createHash } from 'node:crypto';
import type {
  SourceSyncStatus,
  UISpec,
} from '@/lib/uiMockProtocol';

// sha-256 prefix: 16 hex chars is plenty for "did this file change" and keeps
// design.json diffs readable.
export function hashSource(content: string | Buffer): string {
  return createHash('sha256').update(content).digest('hex').slice(0, 16);
}

// Per-screen sync status for every screen with a sourceFile. DI'd reader for
// tests; `null` from the reader = file unreadable/missing. Screens imported
// before hash stamping existed (sourceFile but no sourceHash) report 'synced'
// — staleness is unknowable until the next import stamps a hash.
export async function computeSyncStatuses(
  spec: UISpec,
  readFile: (rel: string) => Promise<Buffer | string | null>,
): Promise<Record<string, SourceSyncStatus>> {
  const out: Record<string, SourceSyncStatus> = {};
  // Multiple screens can share one source file — hash each file once.
  const fileHash = new Map<string, string | null>();
  for (const screen of spec.screens) {
    if (!screen.sourceFile) continue;
    let h = fileHash.get(screen.sourceFile);
    if (h === undefined) {
      const content = await readFile(screen.sourceFile);
      h = content === null ? null : hashSource(content);
      fileHash.set(screen.sourceFile, h);
    }
    if (h === null) out[screen.id] = 'missing';
    else if (screen.sourceHash === undefined) out[screen.id] = 'synced';
    else out[screen.id] = h === screen.sourceHash ? 'synced' : 'stale';
  }
  return out;
}

// Cheap change detector so pure geometry/style edits (drag snapshots land in
// the cache constantly) never trigger a recompute: statuses can only change
// when provenance fields change or a watched file changes.
export function provenanceSignature(spec: UISpec): string {
  return JSON.stringify(
    spec.screens.map((s) => [s.id, s.sourceFile ?? null, s.sourceHash ?? null]),
  );
}
