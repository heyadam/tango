import type { UIMessage } from 'ai';

// The agent is a UI controller, not the brain. It must only use the
// UI/terminal tools. Canvas mutation tools belong to the active terminal agent
// — exposing them here lets gpt-5.5 short-circuit the delegation and do the
// work itself.
export const ALLOWED_TOOLS = new Set([
  'dom_inspect',
  'cursor_move',
  'cursor_click',
  'cursor_type',
  'terminal_type',
]);

export function mcpUrl(req: Request): string {
  // Same-origin: the MCP transport is mounted on this very server. Building
  // off the request URL means it Just Works whether we're on :3000, behind a
  // proxy, or in Electron's loopback.
  const url = new URL(req.url);
  return `${url.protocol}//${url.host}/mcp`;
}

// Pull the most recent user-authored text out of the UI message list. Each
// UIMessage's `parts` is an array of typed parts; we want the first text part
// of the last user message.
export function lastUserGoal(messages: UIMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== 'user') continue;
    const text = (m.parts ?? [])
      .map((p) => (p && (p as { type?: string }).type === 'text' ? (p as { text?: string }).text ?? '' : ''))
      .filter(Boolean)
      .join(' ')
      .trim();
    if (text) return text;
  }
  return '';
}

// Returns a same-typed view of `allTools` with disallowed entries dropped.
// The cast preserves the original record's value type so consumers like
// `streamText`'s ToolSet keep their precise inference.
export function filterAllowedTools<T extends Record<string, unknown>>(
  allTools: T,
  allowed: ReadonlySet<string> = ALLOWED_TOOLS,
): T {
  return Object.fromEntries(
    Object.entries(allTools).filter(([name]) => allowed.has(name)),
  ) as T;
}
