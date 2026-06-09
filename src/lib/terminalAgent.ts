export const TERMINAL_AGENT_IDS = ['claude', 'codex'] as const;

export type TerminalAgentId = (typeof TERMINAL_AGENT_IDS)[number];

export const DEFAULT_TERMINAL_AGENT: TerminalAgentId = 'claude';

export type TerminalAgentMeta = {
  id: TerminalAgentId;
  label: string;
  shortLabel: string;
  executable: string;
  sendLabel: string;
  placeholder: string;
};

export const TERMINAL_AGENTS: Record<TerminalAgentId, TerminalAgentMeta> = {
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
