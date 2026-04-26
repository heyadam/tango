import { describe, it, expect } from 'vitest';
import {
  mergeClaudeMd,
  mergeMcpJson,
  mergeClaudeSettings,
} from './workspace';

const SENTINEL_START = '<!-- tango:start (managed by tango — do not edit) -->';
const SENTINEL_END = '<!-- tango:end -->';
const BLOCK = `${SENTINEL_START}\n@.claude/tango.md\n${SENTINEL_END}`;

describe('mergeClaudeMd', () => {
  it('null input returns just the sentinel block', () => {
    expect(mergeClaudeMd(null)).toBe(BLOCK + '\n');
  });

  it('empty string returns just the sentinel block', () => {
    expect(mergeClaudeMd('')).toBe(BLOCK + '\n');
  });

  it('replaces an existing sentinel block in place', () => {
    const stale = `${SENTINEL_START}\nold body\n${SENTINEL_END}`;
    expect(mergeClaudeMd(stale)).toBe(BLOCK);
  });

  it('preserves content above and below the sentinel byte-for-byte', () => {
    const before = '# My project\n\nSome notes.\n\n';
    const after = '\n\n## Other section\n- bullet\n';
    const stale = `${before}${SENTINEL_START}\nstale\n${SENTINEL_END}${after}`;
    const out = mergeClaudeMd(stale);
    expect(out.startsWith(before)).toBe(true);
    expect(out.endsWith(after)).toBe(true);
    expect(out).toBe(`${before}${BLOCK}${after}`);
  });

  it('appends after one blank line when no sentinel present', () => {
    const out = mergeClaudeMd('# My project\n\nNotes.\n');
    expect(out).toBe(`# My project\n\nNotes.\n\n${BLOCK}\n`);
  });

  it('normalizes trailing whitespace before append (no triple newline)', () => {
    const out = mergeClaudeMd('# Project\n\n\n\n');
    expect(out).toBe(`# Project\n\n${BLOCK}\n`);
  });

  it('is idempotent: f(f(x)) === f(x)', () => {
    const inputs = [
      null,
      '',
      '# Project\n\nNotes.\n',
      `${SENTINEL_START}\nold\n${SENTINEL_END}`,
      `top\n\n${SENTINEL_START}\nx\n${SENTINEL_END}\n\nbottom\n`,
    ];
    for (const x of inputs) {
      const once = mergeClaudeMd(x);
      const twice = mergeClaudeMd(once);
      expect(twice).toBe(once);
    }
  });

  it('only replaces the first sentinel block when two are present', () => {
    const two = `${SENTINEL_START}\nA\n${SENTINEL_END}\n\n${SENTINEL_START}\nB\n${SENTINEL_END}`;
    const out = mergeClaudeMd(two);
    expect(out).toBe(`${BLOCK}\n\n${SENTINEL_START}\nB\n${SENTINEL_END}`);
  });
});

describe('mergeMcpJson', () => {
  it('null input yields a fresh tango-canvas entry only', () => {
    const r = mergeMcpJson(null, 3000);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next)).toEqual({
      mcpServers: {
        'tango-canvas': { type: 'http', url: 'http://localhost:3000/mcp' },
      },
    });
  });

  it('empty string treated as null', () => {
    const r = mergeMcpJson('', 4321);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next).mcpServers['tango-canvas'].url).toBe(
      'http://localhost:4321/mcp',
    );
  });

  it('whitespace-only treated as null', () => {
    const r = mergeMcpJson('   \n\t  ', 5000);
    expect(r.ok).toBe(true);
  });

  it('refuses malformed JSON without claiming success', () => {
    const r = mergeMcpJson('{ not valid', 3000);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toMatch(/not valid JSON/);
  });

  it('refuses non-object root (array)', () => {
    const r = mergeMcpJson('[]', 3000);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toMatch(/not a JSON object/);
  });

  it('refuses non-object root (number)', () => {
    const r = mergeMcpJson('42', 3000);
    expect(r.ok).toBe(false);
  });

  it('refuses non-object root (null literal)', () => {
    const r = mergeMcpJson('null', 3000);
    expect(r.ok).toBe(false);
  });

  it('preserves other mcpServers entries', () => {
    const existing = JSON.stringify({
      mcpServers: {
        github: { type: 'http', url: 'https://api.example/mcp' },
      },
    });
    const r = mergeMcpJson(existing, 3000);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const merged = JSON.parse(r.next);
    expect(merged.mcpServers.github).toEqual({
      type: 'http',
      url: 'https://api.example/mcp',
    });
    expect(merged.mcpServers['tango-canvas'].url).toBe(
      'http://localhost:3000/mcp',
    );
  });

  it('preserves top-level keys outside mcpServers', () => {
    const existing = JSON.stringify({ extension: { theme: 'dark' }, mcpServers: {} });
    const r = mergeMcpJson(existing, 3000);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next).extension).toEqual({ theme: 'dark' });
  });

  it('overwrites a stale tango-canvas port', () => {
    const existing = JSON.stringify({
      mcpServers: {
        'tango-canvas': { type: 'http', url: 'http://localhost:9999/mcp' },
      },
    });
    const r = mergeMcpJson(existing, 3000);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next).mcpServers['tango-canvas'].url).toBe(
      'http://localhost:3000/mcp',
    );
  });
});

describe('mergeClaudeSettings', () => {
  it('null input adds the env override', () => {
    const r = mergeClaudeSettings(null);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next)).toEqual({
      env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1' },
    });
  });

  it('refuses malformed JSON', () => {
    const r = mergeClaudeSettings('{ not valid');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toMatch(/not valid JSON/);
  });

  it('refuses non-object root', () => {
    expect(mergeClaudeSettings('[]').ok).toBe(false);
    expect(mergeClaudeSettings('"hello"').ok).toBe(false);
  });

  it('preserves top-level keys (hooks, theme, model)', () => {
    const existing = JSON.stringify({
      hooks: { Stop: [{ command: 'echo done' }] },
      theme: 'dark',
      model: 'opus',
    });
    const r = mergeClaudeSettings(existing);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const merged = JSON.parse(r.next);
    expect(merged.hooks).toEqual({ Stop: [{ command: 'echo done' }] });
    expect(merged.theme).toBe('dark');
    expect(merged.model).toBe('opus');
  });

  it('preserves existing env keys while adding the agent-teams flag', () => {
    const existing = JSON.stringify({ env: { OTHER_VAR: 'foo' } });
    const r = mergeClaudeSettings(existing);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const merged = JSON.parse(r.next);
    expect(merged.env).toEqual({
      OTHER_VAR: 'foo',
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
    });
  });

  it('overwrites an existing CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0', () => {
    const existing = JSON.stringify({
      env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '0' },
    });
    const r = mergeClaudeSettings(existing);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(JSON.parse(r.next).env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS).toBe('1');
  });
});
