import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  buildTerminalPtyEnv,
  findExecutableOnPath,
  tangoCodexBinDir,
} from './ptyEnv';

describe('PTY environment', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-pty-env-'));
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  async function writeExecutable(p: string): Promise<void> {
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, '#!/bin/sh\nexit 0\n');
    await fs.chmod(p, 0o755);
  }

  it('finds an executable on PATH while skipping the Tango wrapper dir', async () => {
    const workspace = path.join(dir, 'workspace');
    const wrapperDir = tangoCodexBinDir(workspace);
    const realDir = path.join(dir, 'real-bin');
    await writeExecutable(path.join(wrapperDir, 'codex'));
    await writeExecutable(path.join(realDir, 'codex'));

    expect(
      findExecutableOnPath(
        'codex',
        [wrapperDir, realDir].join(path.delimiter),
        [wrapperDir],
      ),
    ).toBe(path.join(realDir, 'codex'));
  });

  it('prepends the Tango Codex wrapper and exposes the MCP URL', async () => {
    const workspace = path.join(dir, 'workspace');
    const realDir = path.join(dir, 'real-bin');
    const realCodex = path.join(realDir, 'codex');
    await writeExecutable(realCodex);

    const env = buildTerminalPtyEnv(workspace, 4321, {
      NODE_ENV: 'test',
      PATH: realDir,
      SHELL: '/bin/zsh',
    });

    expect(env.PATH?.split(path.delimiter)[0]).toBe(tangoCodexBinDir(workspace));
    expect(env.TANGO_MCP_URL).toBe('http://localhost:4321/mcp');
    expect(env.TANGO_CODEX_REAL_BIN).toBe(realCodex);
    expect(env.TERM).toBe('xterm-256color');
    expect(env.COLORTERM).toBe('truecolor');
  });
});
