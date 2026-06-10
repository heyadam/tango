import { afterEach, beforeEach, describe, it, expect } from 'vitest';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  ensureWorkspace,
  mergeAgentsMd,
  mergeClaudeMd,
  mergeMcpJson,
  mergeClaudeSettings,
} from './workspace';

const SENTINEL_START = '<!-- tango:start (managed by tango — do not edit) -->';
const SENTINEL_END = '<!-- tango:end -->';
const BLOCK = `${SENTINEL_START}\n@.claude/tango.md\n${SENTINEL_END}`;
const AGENTS_SENTINEL_START = '<!-- tango-codex:start (managed by tango — do not edit) -->';
const AGENTS_SENTINEL_END = '<!-- tango-codex:end -->';

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

describe('mergeAgentsMd', () => {
  const iosProject = { kind: 'none' } as const;
  const workspace = '/tmp/tango-project';

  it('null input returns a Codex managed block', () => {
    const out = mergeAgentsMd(null, iosProject, workspace);
    expect(out).toContain(AGENTS_SENTINEL_START);
    expect(out).toContain(AGENTS_SENTINEL_END);
    expect(out).toContain('Codex CLI');
    expect(out).toContain('.agents/skills/tango-ui-mock/SKILL.md');
    expect(out).not.toContain('.claude/skills');
  });

  it('preserves content outside the Codex sentinel block', () => {
    const before = '# My agents\n\n';
    const after = '\n\n## Project notes\nKeep this.';
    const stale = `${before}${AGENTS_SENTINEL_START}\nstale\n${AGENTS_SENTINEL_END}${after}`;
    const out = mergeAgentsMd(stale, iosProject, workspace);

    expect(out.startsWith(before)).toBe(true);
    expect(out.endsWith(after)).toBe(true);
    expect(out).toContain('.agents/skills/tango-ui-mock/SKILL.md');
    expect(out).not.toContain('stale');
  });

  it('is idempotent', () => {
    const once = mergeAgentsMd('# Existing\n', iosProject, workspace);
    const twice = mergeAgentsMd(once, iosProject, workspace);
    expect(twice).toBe(once);
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

// End-to-end coverage for the bundled skills emitted by ensureWorkspace.
// The skill bodies themselves are module-private TS template literals; this
// is the only way to assert they reach the workspace correctly. Same test
// shape covers existence, content invariants, and idempotency for the
// tango-swiftui skill (the new one) without exporting implementation
// details.
describe('ensureWorkspace skill emission', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-ensure-'));
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('writes the tango-swiftui skill with the expected shape', async () => {
    const result = await ensureWorkspace(3000, dir);
    expect(result.ok).toBe(true);

    const skillPath = path.join(dir, '.claude', 'skills', 'tango-swiftui', 'SKILL.md');
    const body = await fs.readFile(skillPath, 'utf8');

    // Frontmatter present and well-formed (auto-discovery requires both keys).
    expect(body).toMatch(/^---\nname: tango-swiftui\ndescription: /);
    expect(body).toContain('\n---\n');

    // Trigger surface — the description must mention the load-bearing keywords
    // so Claude Code's skill auto-invocation reliably picks it up.
    expect(body).toContain('SwiftUI');
    expect(body).toContain('.swift');
    expect(body).toContain('Xcode');

    // Both flow directions must be documented.
    expect(body).toContain('Read flow');
    expect(body).toContain('Write flow');

    // Mapping cheat sheets are the load-bearing knowledge for the round-trip.
    expect(body).toContain('SwiftUI → UINode');
    expect(body).toContain('UINode → SwiftUI');

    // Disambiguation from the sibling skill must be explicit so it doesn't
    // steal SwiftUI prompts and vice versa.
    expect(body).toContain('tango-ui-mock');

    // Standard tango trailer marking the file as managed/overwritten.
    expect(body).toContain('overwritten on each server boot');

    const codexSkillPath = path.join(
      dir,
      '.agents',
      'skills',
      'tango-swiftui',
      'SKILL.md',
    );
    const codexBody = await fs.readFile(codexSkillPath, 'utf8');
    expect(codexBody).toMatch(/^---\nname: tango-swiftui\ndescription: /);
    expect(codexBody).toContain('Codex');
    expect(codexBody).toContain('.agents/skills/tango-ui-mock/SKILL.md');
    expect(codexBody).not.toContain('.claude/skills');

    const codexSkillsRoot = path.join(dir, '.agents', 'skills');
    const codexSkillNames = await fs.readdir(codexSkillsRoot);
    expect(codexSkillNames.sort()).toEqual([
      'tango-ios-sim',
      'tango-swiftui',
      'tango-ui-import',
      'tango-ui-mock',
    ]);
    for (const name of codexSkillNames) {
      const emitted = await fs.readFile(
        path.join(codexSkillsRoot, name, 'SKILL.md'),
        'utf8',
      );
      const frontmatter = emitted.match(
        /^---\nname: ([^\n]+)\ndescription: ([^\n]+)\n---\n/,
      );
      expect(frontmatter, name).not.toBeNull();
      if (!frontmatter) continue;
      expect(frontmatter[1]).toBe(name);
      expect(frontmatter[2].length, name).toBeLessThanOrEqual(1024);
      expect(frontmatter[2], name).not.toContain(':');
    }

    const codexWrapperPath = path.join(dir, '.tango', 'bin', 'codex');
    const codexWrapper = await fs.readFile(codexWrapperPath, 'utf8');
    expect(codexWrapper).toContain('TANGO_MCP_URL');
    expect(codexWrapper).toContain('mcp_servers.tango-canvas.url');
    expect(codexWrapper).toContain('trust_level="trusted"');
    expect(codexWrapper).toContain('service_tier="fast"');
    expect((await fs.stat(codexWrapperPath)).mode & 0o111).not.toBe(0);
  });

  it('documents remove_ui_screen, sourceFile, and the variations convention', async () => {
    await ensureWorkspace(3000, dir);

    const tangoMd = await fs.readFile(
      path.join(dir, '.claude', 'tango.md'),
      'utf8',
    );
    expect(tangoMd).toContain('`remove_ui_screen`');
    expect(tangoMd).toContain('prefer over `set_ui_mock` for discarding variations');

    const uiMockSkill = await fs.readFile(
      path.join(dir, '.claude', 'skills', 'tango-ui-mock', 'SKILL.md'),
      'utf8',
    );
    expect(uiMockSkill).toContain('`remove_ui_screen`');
    expect(uiMockSkill).toContain('`remove_ui_screen({ screenId })`');
    expect(uiMockSkill).toContain('sourceFile?: string');
    expect(uiMockSkill).toContain('import provenance');
    expect(uiMockSkill).toContain('## Screen variations');
    expect(uiMockSkill).toContain("'<screenId>-v1'");
    expect(uiMockSkill).toContain("'<Title> · vN'");

    const swiftuiSkill = await fs.readFile(
      path.join(dir, '.claude', 'skills', 'tango-swiftui', 'SKILL.md'),
      'utf8',
    );
    expect(swiftuiSkill).toContain('`remove_ui_screen`');
    expect(swiftuiSkill).toContain('`sourceFile`');
  });

  it('points at tango-swiftui from the always-loaded tango.md', async () => {
    await ensureWorkspace(3000, dir);
    const tangoMd = await fs.readFile(
      path.join(dir, '.claude', 'tango.md'),
      'utf8',
    );
    expect(tangoMd).toContain('tango-swiftui');
    expect(tangoMd).toContain('.claude/skills/tango-swiftui/SKILL.md');

    const agentsMd = await fs.readFile(path.join(dir, 'AGENTS.md'), 'utf8');
    expect(agentsMd).toContain('tango-swiftui');
    expect(agentsMd).toContain('.agents/skills/tango-swiftui/SKILL.md');
    expect(agentsMd).toContain('tango-canvas');
    expect(agentsMd).not.toContain('.claude/skills');
  });

  it('is idempotent — re-running ensure leaves the skill content unchanged', async () => {
    await ensureWorkspace(3000, dir);
    const skillPath = path.join(dir, '.claude', 'skills', 'tango-swiftui', 'SKILL.md');
    const codexSkillPath = path.join(
      dir,
      '.agents',
      'skills',
      'tango-swiftui',
      'SKILL.md',
    );
    const codexWrapperPath = path.join(dir, '.tango', 'bin', 'codex');
    const agentsPath = path.join(dir, 'AGENTS.md');
    const first = await fs.readFile(skillPath, 'utf8');
    const firstCodex = await fs.readFile(codexSkillPath, 'utf8');
    const firstCodexWrapper = await fs.readFile(codexWrapperPath, 'utf8');
    const firstAgents = await fs.readFile(agentsPath, 'utf8');

    const result = await ensureWorkspace(3000, dir);
    expect(result.ok).toBe(true);

    const second = await fs.readFile(skillPath, 'utf8');
    const secondCodex = await fs.readFile(codexSkillPath, 'utf8');
    const secondCodexWrapper = await fs.readFile(codexWrapperPath, 'utf8');
    const secondAgents = await fs.readFile(agentsPath, 'utf8');
    expect(second).toBe(first);
    expect(secondCodex).toBe(firstCodex);
    expect(secondCodexWrapper).toBe(firstCodexWrapper);
    expect(secondAgents).toBe(firstAgents);
    expect((await fs.stat(codexWrapperPath)).mode & 0o111).not.toBe(0);
  });
});
