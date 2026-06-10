// Wire protocol for /ws/agent — the built-in agent panel's bridge to the
// Claude Agent SDK session on the server. JSON text frames both ways (no
// binary channel; there's no raw byte stream like the PTY). Browser-safe:
// no Node imports, shared by AgentPanel and agentBridge.

export type AgentClientMsg =
  | { type: 'user_message'; text: string }
  | { type: 'interrupt' };

export type AgentServerMsg =
  // Engine session established (first message after connect, and again if the
  // underlying session restarts). model is the resolved model id.
  | { type: 'ready'; sessionId: string; model: string }
  // Streaming assistant text. `delta`s accumulate into the current bubble;
  // `text_done` closes it.
  | { type: 'text_delta'; text: string }
  | { type: 'text_done' }
  // The model started composing a tool call (streaming its input). Lets the
  // panel show the tool immediately — large inputs (e.g. a 40-node
  // add_ui_screen) can take minutes to generate and would otherwise look like
  // a hang. Superseded by the tool_use frame once the input is complete.
  | { type: 'tool_pending'; name: string }
  // The agent invoked a tool. detail is a short human-readable summary of the
  // input (see summarizeToolInput).
  | { type: 'tool_use'; name: string; detail: string }
  // One user-visible turn finished (the agent is idle again).
  | {
      type: 'turn_done';
      ok: boolean;
      durationMs?: number;
      costUsd?: number;
      error?: string;
    }
  // Engine-level status worth surfacing ("starting engine…", auth problems).
  | { type: 'status'; text: string }
  | { type: 'error'; message: string }
  // Same control frames the PTY bridge sends, so panels react uniformly.
  | { type: 'workspace_changed' }
  | { type: 'terminal_agent_changed'; agent: string };

// Compact, human-readable one-liner for a tool invocation, shown as a chip in
// the chat transcript. Best-effort: unknown tools fall back to the first
// string-ish input value.
export function summarizeToolInput(
  name: string,
  input: unknown,
): string {
  const obj =
    input && typeof input === 'object' ? (input as Record<string, unknown>) : {};
  const str = (key: string): string | null =>
    typeof obj[key] === 'string' ? (obj[key] as string) : null;

  const firstLine = (s: string, max = 80): string => {
    const line = s.split('\n')[0];
    return line.length > max ? `${line.slice(0, max)}…` : line;
  };

  switch (name) {
    case 'Bash':
      return firstLine(str('command') ?? '');
    case 'Read':
    case 'Write':
    case 'Edit':
    case 'NotebookEdit':
      return shortenPath(str('file_path') ?? '');
    case 'Glob':
    case 'Grep':
      return firstLine(str('pattern') ?? '');
    case 'WebFetch':
      return firstLine(str('url') ?? '');
    case 'WebSearch':
      return firstLine(str('query') ?? '');
    case 'Task':
      return firstLine(str('description') ?? '');
    case 'Skill':
      return firstLine(str('skill') ?? str('command') ?? '');
    case 'TodoWrite':
      return 'update task list';
  }

  // MCP tools (mcp__server__tool) — surface the identifying argument.
  if (name.startsWith('mcp__')) {
    const id =
      str('screenId') ?? str('nodeId') ?? str('scheme') ?? str('text') ?? '';
    return firstLine(id);
  }

  for (const value of Object.values(obj)) {
    if (typeof value === 'string' && value.length > 0) return firstLine(value);
  }
  return '';
}

function shortenPath(p: string): string {
  if (p.length <= 60) return p;
  const parts = p.split('/');
  if (parts.length <= 3) return p;
  return `…/${parts.slice(-3).join('/')}`;
}

// Strip the mcp__server__ prefix for display: mcp__tango-canvas__add_ui_nodes
// → add_ui_nodes.
export function displayToolName(name: string): string {
  if (!name.startsWith('mcp__')) return name;
  const parts = name.split('__');
  return parts[parts.length - 1] || name;
}

// Adapter between terminalBus's PTY-shaped writes and a chat input. The bus's
// submitToTerminal sends the text and then a bare '\r' ~120ms later (two
// separate writes — load-bearing for PTY agents). For the chat panel, text
// chunks accumulate and the '\r' flushes them as one user message.
export function createSubmitBuffer(onSubmit: (text: string) => void): {
  push: (chunk: string) => void;
} {
  let buffer = '';
  return {
    push(chunk: string) {
      if (chunk === '\r' || chunk === '\n' || chunk === '\r\n') {
        const text = buffer.trim();
        buffer = '';
        if (text.length > 0) onSubmit(text);
        return;
      }
      buffer += chunk;
    },
  };
}
