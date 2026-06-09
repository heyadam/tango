import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  _setWorkspaceInternal,
  ensureWorkspace,
  getWorkspaceOrNull,
  getWorkspaceSource,
  type EnsureError,
} from './workspace';
import { callHook } from './serverHooks';
import {
  DEFAULT_TERMINAL_AGENT,
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';

// User-level state file that survives across server restarts. Lives at
// ~/.tango/state.json so it's outside any workspace and not subject to a
// chosen workspace's gitignore. Electron will swap os.homedir() for
// app.getPath('userData') in one place — keep that swap here, not at callers.

type StateFile = {
  lastWorkspace: string | null;
  terminalAgent?: TerminalAgentId;
  // Built-in agent session continuity: workspace path → last Claude Agent
  // SDK session id, so reconnects resume the conversation.
  agentSessions?: Record<string, string>;
};

type TerminalAgentSlot = {
  current: TerminalAgentId;
};

const TERMINAL_AGENT_SLOT_KEY = '__tangoTerminalAgentSlot__';

function getTerminalAgentSlot(): TerminalAgentSlot {
  const g = globalThis as typeof globalThis & {
    [TERMINAL_AGENT_SLOT_KEY]?: TerminalAgentSlot;
  };
  if (!g[TERMINAL_AGENT_SLOT_KEY]) {
    g[TERMINAL_AGENT_SLOT_KEY] = { current: DEFAULT_TERMINAL_AGENT };
  }
  return g[TERMINAL_AGENT_SLOT_KEY];
}

function stateDir(): string {
  return process.env.TANGO_STATE_DIR ?? path.join(os.homedir(), '.tango');
}

function statePath(): string {
  return path.join(stateDir(), 'state.json');
}

export async function loadPersistedWorkspace(): Promise<string | null> {
  const parsed = await readStateFile();
  if (typeof parsed.lastWorkspace === 'string' && parsed.lastWorkspace !== '') {
    return parsed.lastWorkspace;
  }
  return null;
}

export async function loadPersistedTerminalAgent(): Promise<TerminalAgentId> {
  const parsed = await readStateFile();
  return isTerminalAgentId(parsed.terminalAgent)
    ? parsed.terminalAgent
    : DEFAULT_TERMINAL_AGENT;
}

export function getTerminalAgent(): TerminalAgentId {
  return getTerminalAgentSlot().current;
}

export function _setTerminalAgentInternal(agent: TerminalAgentId): void {
  getTerminalAgentSlot().current = agent;
}

async function readStateFile(): Promise<Partial<StateFile>> {
  let raw: string;
  try {
    raw = await fs.readFile(statePath(), 'utf8');
  } catch {
    return {};
  }
  try {
    const parsed = JSON.parse(raw) as Partial<StateFile>;
    if (parsed && typeof parsed === 'object') return parsed;
  } catch {
    // malformed — treat as unset; the picker will rewrite on next select
  }
  return {};
}

function sanitizeAgentSessions(
  value: unknown,
): Record<string, string> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (typeof v === 'string' && v !== '') out[k] = v;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

async function persistState(patch: Partial<StateFile>): Promise<void> {
  await fs.mkdir(stateDir(), { recursive: true });
  const current = await readStateFile();
  const next: StateFile = {
    lastWorkspace:
      typeof current.lastWorkspace === 'string' ? current.lastWorkspace : null,
    terminalAgent: isTerminalAgentId(current.terminalAgent)
      ? current.terminalAgent
      : undefined,
    agentSessions: sanitizeAgentSessions(current.agentSessions),
    ...patch,
  };
  if (!isTerminalAgentId(next.terminalAgent)) {
    delete next.terminalAgent;
  }
  if (next.agentSessions === undefined) {
    delete next.agentSessions;
  }
  await fs.writeFile(statePath(), JSON.stringify(next, null, 2) + '\n');
}

export async function loadPersistedAgentSession(
  workspace: string,
): Promise<string | null> {
  const parsed = await readStateFile();
  const sessions = sanitizeAgentSessions(parsed.agentSessions);
  return sessions?.[workspace] ?? null;
}

export async function persistAgentSession(
  workspace: string,
  sessionId: string,
): Promise<void> {
  const current = await readStateFile();
  const sessions = sanitizeAgentSessions(current.agentSessions) ?? {};
  if (sessions[workspace] === sessionId) return;
  sessions[workspace] = sessionId;
  await persistState({ agentSessions: sessions });
}

async function persistWorkspace(absPath: string | null): Promise<void> {
  await persistState({ lastWorkspace: absPath });
}

export type SetWorkspaceOk = {
  ok: true;
  path: string;
  // Soft errors — workspace is usable, but one of the merges refused (e.g.,
  // existing .mcp.json was malformed and we didn't want to clobber it).
  errors?: EnsureError[];
};

export type SetWorkspaceErr =
  | { ok: false; code: 'env_locked' }
  | { ok: false; code: 'invalid_path'; reason: string }
  | { ok: false; code: 'ensure_failed'; reason: string };

export type SetWorkspaceResult = SetWorkspaceOk | SetWorkspaceErr;

async function validatePath(input: string): Promise<{ ok: true; abs: string } | { ok: false; reason: string }> {
  if (typeof input !== 'string' || input.trim() === '') {
    return { ok: false, reason: 'path is required' };
  }
  // Expand a leading ~ — common when users paste from a shell.
  let raw = input.trim();
  if (raw.startsWith('~/') || raw === '~') {
    raw = path.join(os.homedir(), raw.slice(1));
  }
  if (!path.isAbsolute(raw)) {
    return { ok: false, reason: 'path must be absolute (e.g. /Users/you/dev/myproject)' };
  }
  const abs = path.resolve(raw);
  if (abs === '/' || abs === path.parse(abs).root) {
    return { ok: false, reason: 'refusing to use the filesystem root as a workspace' };
  }
  if (abs === os.homedir()) {
    return { ok: false, reason: 'refusing to use your home directory as a workspace' };
  }
  let stat;
  try {
    stat = await fs.stat(abs);
  } catch {
    return { ok: false, reason: `directory not found: ${abs}` };
  }
  if (!stat.isDirectory()) {
    return { ok: false, reason: `not a directory: ${abs}` };
  }
  try {
    // R_OK | W_OK — we need to write CLAUDE.md and friends.
    await fs.access(abs, fs.constants.R_OK | fs.constants.W_OK);
  } catch {
    return { ok: false, reason: `directory is not readable+writable: ${abs}` };
  }
  return { ok: true, abs };
}

// Validate-only: same checks as setWorkspace, but doesn't write anything or
// mutate state. Used for the picker's debounced existence check.
export async function dryRunSetWorkspace(input: string): Promise<SetWorkspaceResult> {
  if (getWorkspaceSource() === 'env') {
    return { ok: false, code: 'env_locked' };
  }
  const v = await validatePath(input);
  if (!v.ok) return { ok: false, code: 'invalid_path', reason: v.reason };
  // Don't actually run ensureWorkspace; just say the path is acceptable.
  return { ok: true, path: v.abs };
}

export async function setWorkspace(
  port: number,
  input: string,
): Promise<SetWorkspaceResult> {
  if (getWorkspaceSource() === 'env') {
    return { ok: false, code: 'env_locked' };
  }
  const v = await validatePath(input);
  if (!v.ok) return { ok: false, code: 'invalid_path', reason: v.reason };
  const abs = v.abs;

  let ensureResult: Awaited<ReturnType<typeof ensureWorkspace>>;
  try {
    ensureResult = await ensureWorkspace(port, abs);
  } catch (err) {
    return {
      ok: false,
      code: 'ensure_failed',
      reason: err instanceof Error ? err.message : String(err),
    };
  }

  const previous = getWorkspaceOrNull();
  const isSwitch = previous !== null && previous !== abs;

  _setWorkspaceInternal(abs, 'persisted');
  try {
    await persistWorkspace(abs);
  } catch (err) {
    // Persistence failure is non-fatal — the workspace is still usable for
    // this session. Log and surface as a soft error.
    console.warn('tango: failed to persist workspace state', err);
  }

  if (isSwitch) {
    // Clear the design cache and broadcast an empty spec so any open browser
    // sees the reset before its terminal reconnects. These hooks live in
    // server.ts's module graph; we reach them via the cross-context registry.
    callHook('resetUiMock');
    callHook('broadcastWorkspaceChanged');
    callHook('agentBroadcastWorkspaceChanged');
  }

  if (ensureResult.ok) {
    return { ok: true, path: abs };
  }
  return { ok: true, path: abs, errors: ensureResult.errors };
}

export type SetTerminalAgentResult =
  | { ok: true; agent: TerminalAgentId }
  | { ok: false; code: 'invalid_agent'; reason: string };

export async function setTerminalAgent(
  input: unknown,
): Promise<SetTerminalAgentResult> {
  if (!isTerminalAgentId(input)) {
    return {
      ok: false,
      code: 'invalid_agent',
      reason: 'agent must be "tango", "claude", or "codex"',
    };
  }

  _setTerminalAgentInternal(input);
  try {
    await persistState({ terminalAgent: input });
  } catch (err) {
    // Persistence failure is non-fatal for the current process.
    console.warn('tango: failed to persist terminal agent state', err);
  }
  callHook('broadcastTerminalAgentChanged');
  callHook('agentBroadcastTerminalAgentChanged');
  return { ok: true, agent: input };
}
