export const TERMINAL_AGENT_IDS = ['tango', 'claude', 'codex'] as const;

export type TerminalAgentId = (typeof TERMINAL_AGENT_IDS)[number];

export const DEFAULT_TERMINAL_AGENT: TerminalAgentId = 'tango';

export type TerminalAgentMeta = {
  id: TerminalAgentId;
  label: string;
  shortLabel: string;
  // CLI executable for PTY-hosted agents; '' for the built-in harness, which
  // runs in-process via the Claude Agent SDK (no PTY, no CLI on PATH needed).
  executable: string;
  sendLabel: string;
  placeholder: string;
};

export const TERMINAL_AGENTS: Record<TerminalAgentId, TerminalAgentMeta> = {
  tango: {
    id: 'tango',
    label: 'Tango Agent',
    shortLabel: 'Tango',
    executable: '',
    sendLabel: 'Send to Tango',
    placeholder: 'The built-in agent will start once a workspace is selected.',
  },
  claude: {
    id: 'claude',
    label: 'Claude Code',
    shortLabel: 'Claude',
    executable: 'claude',
    sendLabel: 'Send to Claude',
    placeholder: 'Claude will start once a workspace is selected.',
  },
  codex: {
    id: 'codex',
    label: 'Codex CLI',
    shortLabel: 'Codex',
    executable: 'codex',
    sendLabel: 'Send to Codex',
    placeholder: 'Codex will start once a workspace is selected.',
  },
};

export function isTerminalAgentId(value: unknown): value is TerminalAgentId {
  return (
    typeof value === 'string' &&
    (TERMINAL_AGENT_IDS as readonly string[]).includes(value)
  );
}

export function terminalAgentOrDefault(value: unknown): TerminalAgentId {
  return isTerminalAgentId(value) ? value : DEFAULT_TERMINAL_AGENT;
}

// Does this agent run inside the PTY-backed xterm panel (vs the built-in
// chat panel backed by /ws/agent)?
export function isPtyAgent(agent: TerminalAgentId): boolean {
  return agent !== 'tango';
}
