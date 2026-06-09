import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { GET, POST } from './route';
import { _setTerminalAgentInternal } from '@/server/workspaceState';

let stateDir: string;

beforeEach(async () => {
  stateDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-agent-api-'));
  process.env.TANGO_STATE_DIR = stateDir;
  _setTerminalAgentInternal('claude');
});

afterEach(async () => {
  _setTerminalAgentInternal('claude');
  delete process.env.TANGO_STATE_DIR;
  await fs.rm(stateDir, { recursive: true, force: true });
});

function request(body: unknown): Request {
  return new Request('http://localhost:3000/api/terminal-agent', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

describe('/api/terminal-agent', () => {
  it('GET returns the active terminal agent', async () => {
    _setTerminalAgentInternal('codex');

    const res = await GET();

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ agent: 'codex' });
  });

  it('POST accepts and persists a valid terminal agent', async () => {
    const res = await POST(request({ agent: 'codex' }));

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, agent: 'codex' });
    const state = JSON.parse(
      await fs.readFile(path.join(stateDir, 'state.json'), 'utf8'),
    );
    expect(state.terminalAgent).toBe('codex');
  });

  it('POST rejects invalid terminal agents', async () => {
    const res = await POST(request({ agent: 'bad' }));

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.ok).toBe(false);
    expect(body.code).toBe('invalid_agent');
  });
});
