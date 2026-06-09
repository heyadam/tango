// Workspace memory file: ${WORKSPACE_DIR}/tango-memory.md
//
// One markdown file split into three managed sections via HTML-comment fences,
// plus a fourth fence reserved for the user. We append events to `Recent`
// synchronously (queued, atomic), and periodically rewrite `Summary` via an
// LLM call when `Recent` gets large. Hooks (snapshot route, agent route,
// remember_note MCP tool) call `appendEvent` / `recordNote` fire-and-forget;
// they never await LLM work.
//
// Create-if-absent semantics: ensureMemory() leaves an existing file alone;
// missing files get a fresh skeleton. Malformed files (no fences) get the
// existing content tucked into the user-notes block, never destroyed.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { generateText, openai, VISION_MODEL } from '@/lib/ai';
import { getWorkspaceOrNull } from './workspace';

const FILE_NAME = 'tango-memory.md';

// Trigger summarization once Recent exceeds either of these.
const RECENT_BYTES_THRESHOLD = 8 * 1024;
const RECENT_ENTRIES_THRESHOLD = 30;
// How many freshest Recent entries to keep verbatim after summarization.
const RECENT_KEEP_AFTER_SUMMARY = 5;

const SUMMARIZATION_TIMEOUT_MS = 20_000;
const SUMMARY_MAX_TOKENS = 800;

// Fence markers. The `v=` and `updated=` attributes on summary:start are
// informational — we replace the whole block on rewrite, so attributes can
// drift without breaking the parser.
const SUMMARY_START_RE = /<!-- tango:summary:start[^>]*-->/;
const SUMMARY_END = '<!-- tango:summary:end -->';
const RECENT_START = '<!-- tango:recent:start -->';
const RECENT_END = '<!-- tango:recent:end -->';
const USER_START = '<!-- tango:user:start -->';
const USER_END = '<!-- tango:user:end -->';

const HEADER = `# tango workspace memory

This file is maintained by tango. The Summary and Recent sections are
periodically rewritten by an LLM (the same OpenAI key as the controller
agent). Anything inside the \`tango:user\` block at the bottom is preserved
verbatim — put your own notes there.`;

function summaryStartTag(updatedIso: string): string {
  return `<!-- tango:summary:start v=1 updated=${updatedIso} -->`;
}

function emptySkeleton(): string {
  return `${HEADER}

${summaryStartTag(new Date().toISOString())}
## Summary

_No prior history yet._
${SUMMARY_END}

${RECENT_START}
## Recent

${RECENT_END}

${USER_START}
## Notes (yours — never touched by tango)

${USER_END}
`;
}

export type MemoryEvent =
  | { type: 'snapshot'; relPath: string; caption?: string }
  | { type: 'agent_run'; goal: string; tools: string; outcome: string }
  | { type: 'note'; category: 'decision' | 'context' | 'todo'; text: string };

// ---- file I/O ---------------------------------------------------------------

function memoryPath(workspaceOverride?: string): string | null {
  const ws = workspaceOverride ?? getWorkspaceOrNull();
  return ws ? path.join(ws, FILE_NAME) : null;
}

async function readUtf8OrNull(p: string): Promise<string | null> {
  try {
    return await fs.readFile(p, 'utf8');
  } catch {
    return null;
  }
}

// Atomic-on-Darwin/Linux: same-fs rename is atomic, so a kill -9 mid-write
// leaves either the old file or the new file, never a half-written truncation.
async function atomicWrite(dest: string, content: string): Promise<void> {
  const tmp = `${dest}.${randomBytes(4).toString('hex')}.tmp`;
  await fs.writeFile(tmp, content);
  try {
    await fs.rename(tmp, dest);
  } catch (err) {
    // Best-effort cleanup if rename failed.
    try {
      await fs.unlink(tmp);
    } catch {
      /* noop */
    }
    throw err;
  }
}

// ---- fence parser/rewriter --------------------------------------------------

type Parsed = {
  // The text before the first managed fence (the file header). Preserved
  // verbatim across rewrites.
  header: string;
  summary: string; // body inside summary fences (without fences themselves)
  recent: string; // body inside recent fences
  user: string; // body inside user fences
  // The text after the user fence. Should be empty in well-formed files.
  trailer: string;
};

/** @internal exported for tests */
export function sliceBetween(
  src: string,
  startRe: RegExp | string,
  end: string,
): { before: string; body: string; after: string } | null {
  const startMatch =
    typeof startRe === 'string'
      ? (() => {
          const i = src.indexOf(startRe);
          return i < 0 ? null : { index: i, length: startRe.length };
        })()
      : (() => {
          const m = startRe.exec(src);
          return m ? { index: m.index, length: m[0].length } : null;
        })();
  if (!startMatch) return null;
  const bodyStart = startMatch.index + startMatch.length;
  const endIdx = src.indexOf(end, bodyStart);
  if (endIdx < 0) return null;
  return {
    before: src.slice(0, startMatch.index),
    body: src.slice(bodyStart, endIdx),
    after: src.slice(endIdx + end.length),
  };
}

/** @internal exported for tests */
export function parseFile(raw: string): Parsed | null {
  const summary = sliceBetween(raw, SUMMARY_START_RE, SUMMARY_END);
  if (!summary) return null;
  const recent = sliceBetween(summary.after, RECENT_START, RECENT_END);
  if (!recent) return null;
  const user = sliceBetween(recent.after, USER_START, USER_END);
  if (!user) return null;
  return {
    header: summary.before,
    summary: summary.body,
    recent: recent.body,
    user: user.body,
    trailer: user.after,
  };
}

/** @internal exported for tests */
export function serialize(p: Parsed, summaryUpdatedIso: string): string {
  const trailer = p.trailer.replace(/\s+$/, '');
  return (
    p.header +
    summaryStartTag(summaryUpdatedIso) +
    p.summary +
    SUMMARY_END +
    '\n\n' +
    RECENT_START +
    p.recent +
    RECENT_END +
    '\n\n' +
    USER_START +
    p.user +
    USER_END +
    (trailer ? `\n${trailer}` : '') +
    '\n'
  );
}

// Wraps an existing-but-malformed file's content into the user-notes block
// so we never destroy what the user wrote, even by accident.
/** @internal exported for tests */
export function rescueMalformed(existing: string): string {
  const skel = emptySkeleton();
  // Inject the existing content as the body of the user block.
  return skel.replace(
    `${USER_START}\n## Notes (yours — never touched by tango)\n\n${USER_END}`,
    `${USER_START}\n## Notes (yours — never touched by tango)\n\n_The following was found in this file before tango took it over; tango never edits it:_\n\n${existing.trim()}\n${USER_END}`,
  );
}

// ---- formatting helpers -----------------------------------------------------

function nowIso(): string {
  return new Date().toISOString();
}

function oneLine(s: string): string {
  return s.replace(/\s+/g, ' ').trim();
}

function truncate(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, Math.max(0, n - 1)).trimEnd() + '…';
}

/** @internal exported for tests */
export function formatEntry(evt: MemoryEvent, ts: string): string {
  switch (evt.type) {
    case 'snapshot': {
      const cap = evt.caption ? ` — "${oneLine(evt.caption)}"` : '';
      return `- ${ts} [snapshot] ${evt.relPath}${cap}`;
    }
    case 'agent_run': {
      const goal = truncate(oneLine(evt.goal), 120);
      const outcome = truncate(oneLine(evt.outcome), 120) || '—';
      return `- ${ts} [agent_run] "${goal}" → ${evt.tools || 'no tools'} → ${outcome}`;
    }
    case 'note':
      return `- ${ts} [note/${evt.category}] ${oneLine(evt.text)}`;
  }
}

/** @internal exported for tests */
export function countRecentEntries(recent: string): number {
  return recent
    .split('\n')
    .filter((l) => l.trim().startsWith('- '))
    .length;
}

// ---- write queue ------------------------------------------------------------

// Serial chain: every queued task runs after the previous one settles.
// .then(task, task) means we run regardless of whether the prior task
// resolved or rejected. The trailing .catch(() => {}) keeps the chain
// from ever holding a rejected state that would suppress later work.
let chain: Promise<void> = Promise.resolve();
function enqueue(task: () => Promise<void>): void {
  chain = chain.then(task, task).catch(() => {});
}

// Flag prevents stacking summarization passes on top of in-flight ones.
// An append that lands while we're summarizing still goes to disk; the
// summarize pass it would have triggered is skipped (the next append
// after this one finishes will catch up).
let summarizing = false;

// ---- public surface ---------------------------------------------------------

// Idempotent. If the file is missing, write a fresh skeleton. If present and
// well-formed, leave it alone. If present but malformed (no fences), wrap
// existing content into the user-notes block.
//
// The caller passes the workspace path explicitly because ensureWorkspace
// (the only caller) runs before the workspace slot is mutated in the
// setWorkspace flow — falling back on getWorkspaceOrNull() here would write
// into the previously-active workspace.
export async function ensureMemory(workspace?: string): Promise<void> {
  const p = memoryPath(workspace);
  if (!p) return;
  const existing = await readUtf8OrNull(p);
  if (existing == null) {
    await atomicWrite(p, emptySkeleton());
    return;
  }
  if (parseFile(existing) != null) return;
  await atomicWrite(p, rescueMalformed(existing));
}

export function appendEvent(evt: MemoryEvent): void {
  enqueue(() => doAppend(evt));
}

export function recordNote(
  category: 'decision' | 'context' | 'todo',
  text: string,
): void {
  if (!text || !text.trim()) return;
  appendEvent({ type: 'note', category, text });
}

async function doAppend(evt: MemoryEvent): Promise<void> {
  const p = memoryPath();
  if (!p) return; // workspace unset — drop silently
  let raw = await readUtf8OrNull(p);
  if (raw == null) {
    // Race: someone deleted the file. Recreate so the append doesn't get lost.
    raw = emptySkeleton();
  }
  let parsed = parseFile(raw);
  if (!parsed) {
    // Malformed mid-flight (user replaced the file?). Rescue and reparse.
    const rescued = rescueMalformed(raw);
    await atomicWrite(p, rescued);
    parsed = parseFile(rescued);
    if (!parsed) return; // shouldn't happen — emptySkeleton always parses
  }

  const line = formatEntry(evt, nowIso());
  // Recent body convention: `\n## Recent\n\n<entries>\n`. Insert before the
  // trailing newline-and-end-fence area so entries stack chronologically.
  const trimmedRecent = parsed.recent.replace(/\s+$/, '');
  const nextRecent =
    (trimmedRecent.length === 0 ? '\n## Recent\n' : trimmedRecent) +
    `\n${line}\n`;
  const next: Parsed = { ...parsed, recent: nextRecent };
  await atomicWrite(p, serialize(next, parsed.summary ? prevUpdated(raw) : nowIso()));

  // Maybe summarize. If already in flight, skip — next append after it
  // finishes will retrigger.
  const recentBytes = Buffer.byteLength(nextRecent, 'utf8');
  const recentCount = countRecentEntries(nextRecent);
  const shouldSummarize =
    !summarizing &&
    (recentBytes > RECENT_BYTES_THRESHOLD ||
      recentCount > RECENT_ENTRIES_THRESHOLD);
  if (shouldSummarize) {
    summarizing = true;
    enqueue(async () => {
      try {
        await summarizeOnce(p);
      } finally {
        summarizing = false;
      }
    });
  }
}

// Read the existing summary:start tag's `updated=` attribute so a routine
// append doesn't claim summary recency it didn't earn.
function prevUpdated(raw: string): string {
  const m = /<!-- tango:summary:start[^>]*updated=([^\s>]+)/.exec(raw);
  return m ? m[1] : nowIso();
}

// ---- summarization ---------------------------------------------------------

const SUMMARY_SYSTEM = `You're maintaining a rolling memory file for future terminal-agent sessions in this workspace. Merge the existing Summary with these new entries. Preserve verbatim: design decisions and user-stated constraints. Collapse routine UI activity into one-liner trends. Output Markdown only, no preamble. Cap ~600 words.`;

async function summarizeOnce(p: string): Promise<void> {
  const raw = await readUtf8OrNull(p);
  if (raw == null) return;
  const parsed = parseFile(raw);
  if (!parsed) return;

  const lines = parsed.recent.split('\n');
  const entryLines = lines.filter((l) => l.trim().startsWith('- '));
  if (entryLines.length === 0) return;

  // Keep the freshest N entries raw, fold the rest.
  const keepCount = Math.min(RECENT_KEEP_AFTER_SUMMARY, entryLines.length);
  const kept = entryLines.slice(-keepCount);
  const folded = entryLines.slice(0, entryLines.length - keepCount);

  if (folded.length === 0) return; // nothing to summarize

  const userPrompt =
    `## Existing Summary\n${parsed.summary.trim() || '_(empty)_'}\n\n## New Entries\n${folded.join('\n')}\n\nReturn the merged Summary as Markdown only.`;

  let nextSummary: string;
  try {
    const result = await generateText({
      model: openai(VISION_MODEL),
      system: SUMMARY_SYSTEM,
      prompt: userPrompt,
      maxOutputTokens: SUMMARY_MAX_TOKENS,
      abortSignal: AbortSignal.timeout(SUMMARIZATION_TIMEOUT_MS),
      providerOptions: {
        openai: { reasoningEffort: 'low' },
      },
    });
    const text = (result.text ?? '').trim();
    if (!text) {
      console.error('[memory] summarization returned empty text — keeping recent entries');
      return;
    }
    nextSummary = text;
  } catch (err) {
    console.error(
      '[memory] summarization failed:',
      err instanceof Error ? err.message : String(err),
    );
    return;
  }

  // Re-read in case more appends landed during the LLM call. Keep those —
  // anything beyond the entries we folded is fresh and should remain raw.
  const raw2 = await readUtf8OrNull(p);
  if (raw2 == null) return;
  const parsed2 = parseFile(raw2);
  if (!parsed2) return;

  const lines2 = parsed2.recent.split('\n');
  const entries2 = lines2.filter((l) => l.trim().startsWith('- '));
  // The folded set is a prefix of the entries we saw at LLM-call time. Drop
  // exactly that many from the head of the current entries, regardless of
  // whether new ones have been appended since.
  const remaining = entries2.slice(folded.length);
  const newRecent =
    `\n## Recent\n` + (remaining.length ? '\n' + remaining.join('\n') + '\n' : '\n');

  const newSummaryBody = `\n## Summary\n\n${nextSummary}\n`;

  const next: Parsed = {
    ...parsed2,
    summary: newSummaryBody,
    recent: newRecent,
  };

  try {
    await atomicWrite(p, serialize(next, nowIso()));
  } catch (err) {
    console.error(
      '[memory] failed to write summarized file:',
      err instanceof Error ? err.message : String(err),
    );
  }
}
