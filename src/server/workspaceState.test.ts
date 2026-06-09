import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  _setTerminalAgentInternal,
  dryRunSetWorkspace,
  getTerminalAgent,
  loadPersistedAgentSession,
  loadPersistedTerminalAgent,
  persistAgentSession,
  setTerminalAgent,
} from './workspaceState';
import { _setWorkspaceInternal } from './workspace';
import { DEFAULT_TERMINAL_AGENT } from '@/lib/terminalAgent';

// We test validatePath through dryRunSetWorkspace: it's the public surface that
// invokes validation without writing anything to disk or mutating the slot.
//
// dryRunSetWorkspace short-circuits with `env_locked` when the workspace
// source is 'env'. The slot defaults to 'unset' and process.env.TANGO_WORKSPACE
// is only read inside resolveWorkspaceAtBoot (never at module init), so a
// fresh import sees source='unset' and validation runs end to end.

let createdDirs: string[] = [];

beforeEach(() => {
  createdDirs = [];
});

afterEach(async () => {
  for (const d of createdDirs) {
    await fs.rm(d, { recursive: true, force: true });
  }
  // Defensive: future cases that call setWorkspace would mutate the slot.
  // Keep the reset so test order doesn't matter.
  _setWorkspaceInternal(null, 'unset');
  _setTerminalAgentInternal(DEFAULT_TERMINAL_AGENT);
  delete process.env.TANGO_STATE_DIR;
});

async function mkTmpDir(): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-test-'));
  createdDirs.push(dir);
  return dir;
}

describe('dryRunSetWorkspace (validatePath)', () => {
  it('rejects empty string', async () => {
    const r = await dryRunSetWorkspace('');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code).toBe('invalid_path');
    if (r.code !== 'invalid_path') return;
    expect(r.reason).toMatch(/path is required/);
  });

  it('rejects whitespace-only string', async () => {
    const r = await dryRunSetWorkspace('   \t  ');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/path is required/);
  });

  it('rejects relative paths', async () => {
    const r = await dryRunSetWorkspace('foo/bar');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/must be absolute/);
  });

  it('rejects the filesystem root', async () => {
    const r = await dryRunSetWorkspace('/');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/filesystem root/);
  });

  it('rejects the home directory exactly', async () => {
    const r = await dryRunSetWorkspace(os.homedir());
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/home directory/);
  });

  it('rejects a non-existent path', async () => {
    const dir = await mkTmpDir();
    const missing = path.join(dir, 'does-not-exist');
    const r = await dryRunSetWorkspace(missing);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/directory not found/);
  });

  it('rejects a path that is a file, not a directory', async () => {
    const dir = await mkTmpDir();
    const file = path.join(dir, 'file.txt');
    await fs.writeFile(file, 'hi');
    const r = await dryRunSetWorkspace(file);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.code === 'invalid_path' && r.reason).toMatch(/not a directory/);
  });

  it('accepts a valid existing directory', async () => {
    const dir = await mkTmpDir();
    const r = await dryRunSetWorkspace(dir);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.path).toBe(dir);
  });

  it('expands a leading ~ to the home directory', async () => {
    // We can't rely on a writable subdir of homedir existing in CI, so just
    // assert the expansion happened by checking the rejection reason mentions
    // an absolute path beneath homedir.
    const r = await dryRunSetWorkspace('~/__tango_test_does_not_exist__');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    if (r.code !== 'invalid_path') return;
    expect(r.reason).toContain(os.homedir());
  });

  // Skip on Windows (no POSIX perms) and when running as root (bypasses them).
  it.skipIf(process.platform === 'win32' || process.getuid?.() === 0)(
    'rejects a directory without read+write permission',
    async () => {
      const dir = await mkTmpDir();
      await fs.chmod(dir, 0o000);
      try {
        const r = await dryRunSetWorkspace(dir);
        expect(r.ok).toBe(false);
        if (r.ok) return;
        expect(r.code === 'invalid_path' && r.reason).toMatch(
          /readable\+writable/,
        );
      } finally {
        // Restore so afterEach can rm -rf it.
        await fs.chmod(dir, 0o700);
      }
    },
  );
});

describe('terminal agent persisted state', () => {
  async function useStateDir(): Promise<string> {
    const dir = await mkTmpDir();
    process.env.TANGO_STATE_DIR = dir;
    return dir;
  }

  it('defaults to the built-in agent when the state file is absent', async () => {
    await useStateDir();
    expect(await loadPersistedTerminalAgent()).toBe(DEFAULT_TERMINAL_AGENT);
  });

  it('defaults to the built-in agent when the state file contains an invalid agent', async () => {
    const dir = await useStateDir();
    await fs.writeFile(
      path.join(dir, 'state.json'),
      JSON.stringify({ terminalAgent: 'bad' }),
    );
    expect(await loadPersistedTerminalAgent()).toBe(DEFAULT_TERMINAL_AGENT);
  });

  it('persists a valid terminal agent without clobbering lastWorkspace', async () => {
    const dir = await useStateDir();
    await fs.writeFile(
      path.join(dir, 'state.json'),
      JSON.stringify({ lastWorkspace: '/tmp/project' }),
    );

    const result = await setTerminalAgent('codex');

    expect(result).toEqual({ ok: true, agent: 'codex' });
    expect(getTerminalAgent()).toBe('codex');
    const state = JSON.parse(
      await fs.readFile(path.join(dir, 'state.json'), 'utf8'),
    );
    expect(state).toEqual({
      lastWorkspace: '/tmp/project',
      terminalAgent: 'codex',
    });
  });

  it('rejects invalid terminal agents and leaves the current value unchanged', async () => {
    await useStateDir();
    _setTerminalAgentInternal('codex');

    const result = await setTerminalAgent('bad');

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.code).toBe('invalid_agent');
    expect(getTerminalAgent()).toBe('codex');
  });

  it('accepts the built-in tango agent', async () => {
    await useStateDir();
    const result = await setTerminalAgent('tango');
    expect(result).toEqual({ ok: true, agent: 'tango' });
    expect(getTerminalAgent()).toBe('tango');
  });
});

describe('agent session persisted state', () => {
  async function useStateDir(): Promise<string> {
    const dir = await mkTmpDir();
    process.env.TANGO_STATE_DIR = dir;
    return dir;
  }

  it('round-trips a session id per workspace', async () => {
    await useStateDir();
    expect(await loadPersistedAgentSession('/tmp/a')).toBeNull();
    await persistAgentSession('/tmp/a', 'sess-1');
    await persistAgentSession('/tmp/b', 'sess-2');
    expect(await loadPersistedAgentSession('/tmp/a')).toBe('sess-1');
    expect(await loadPersistedAgentSession('/tmp/b')).toBe('sess-2');
  });

  it('survives unrelated state writes', async () => {
    await useStateDir();
    await persistAgentSession('/tmp/a', 'sess-1');
    await setTerminalAgent('codex');
    expect(await loadPersistedAgentSession('/tmp/a')).toBe('sess-1');
  });

  it('ignores malformed agentSessions entries', async () => {
    const dir = await useStateDir();
    await fs.writeFile(
      path.join(dir, 'state.json'),
      JSON.stringify({
        lastWorkspace: null,
        agentSessions: { '/tmp/a': 42, '/tmp/b': 'ok' },
      }),
    );
    expect(await loadPersistedAgentSession('/tmp/a')).toBeNull();
    expect(await loadPersistedAgentSession('/tmp/b')).toBe('ok');
  });
});
