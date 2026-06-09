import { describe, expect, it } from 'vitest';
import {
  DEFAULT_TERMINAL_AGENT,
  isTerminalAgentId,
  terminalAgentOrDefault,
} from '@/lib/terminalAgent';
import {
  terminalAgentFromQuery,
  terminalAgentLaunchCommand,
  terminalAgentMcpUrl,
} from './terminalAgent';

describe('terminal agent validation', () => {
  it('accepts only supported terminal agent ids', () => {
    expect(isTerminalAgentId('tango')).toBe(true);
    expect(isTerminalAgentId('claude')).toBe(true);
    expect(isTerminalAgentId('codex')).toBe(true);
    expect(isTerminalAgentId('cursor')).toBe(false);
    expect(isTerminalAgentId(null)).toBe(false);
  });

  it('defaults to the built-in agent', () => {
    expect(DEFAULT_TERMINAL_AGENT).toBe('tango');
  });

  it('falls back to the default agent for invalid values', () => {
    expect(terminalAgentOrDefault('codex')).toBe('codex');
    expect(terminalAgentOrDefault('bad')).toBe(DEFAULT_TERMINAL_AGENT);
    expect(terminalAgentFromQuery('codex')).toBe('codex');
    expect(terminalAgentFromQuery('bad')).toBeNull();
  });
});

describe('terminalAgentLaunchCommand', () => {
  it('builds the Tango MCP URL for the active server port', () => {
    expect(terminalAgentMcpUrl(4321)).toBe('http://localhost:4321/mcp');
  });

  it('builds the Claude Code launch command', () => {
    expect(terminalAgentLaunchCommand('claude', 3000)).toBe(
      'claude --dangerously-skip-permissions',
    );
  });

  it("falls back to Claude Code for 'tango' (built-in agent never runs in a PTY)", () => {
    expect(terminalAgentLaunchCommand('tango', 3000)).toBe(
      'claude --dangerously-skip-permissions',
    );
  });

  it('builds the Codex launch command with session-scoped MCP config', () => {
    expect(terminalAgentLaunchCommand('codex', 4321)).toBe(
      [
        'codex',
        '-m gpt-5.5',
        '-c',
        '\'trust_level="trusted"\'',
        '-c',
        '\'service_tier="fast"\'',
        '-c',
        '\'mcp_servers.tango-canvas.url="http://localhost:4321/mcp"\'',
        '--dangerously-bypass-approvals-and-sandbox',
      ].join(' '),
    );
  });
});
