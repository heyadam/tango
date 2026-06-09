import {
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';

export function terminalAgentFromQuery(value: unknown): TerminalAgentId | null {
  return isTerminalAgentId(value) ? value : null;
}

export function terminalAgentMcpUrl(port: number): string {
  return `http://localhost:${port}/mcp`;
}

function shellSingleQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function terminalAgentLaunchCommand(
  agent: TerminalAgentId,
  port: number,
): string {
  // 'tango' is the built-in (non-PTY) agent — it never legitimately reaches a
  // PTY launch. A direct /ws/terminal hit while 'tango' is selected falls
  // back to Claude Code rather than executing nothing.
  if (agent === 'claude' || agent === 'tango') {
    return 'claude --dangerously-skip-permissions';
  }

  const mcpUrl = terminalAgentMcpUrl(port);
  return [
    'codex',
    '-m gpt-5.5',
    '-c',
    shellSingleQuote('trust_level="trusted"'),
    '-c',
    shellSingleQuote('service_tier="fast"'),
    '-c',
    shellSingleQuote(`mcp_servers.tango-canvas.url="${mcpUrl}"`),
    '--dangerously-bypass-approvals-and-sandbox',
  ].join(' ');
}
