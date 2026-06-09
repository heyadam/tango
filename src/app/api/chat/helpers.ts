import type { UIMessage } from 'ai';

// The chat harness IS the brain — it sees every MCP tool that's part of the
// design / build / iOS workflow. The cursor/terminal-puppeting tools from the
// old controller agent are intentionally excluded; with no terminal-Claude to
// delegate to, they have no reason to exist on this surface.
export const ALLOWED_TOOLS = new Set([
  // canvas
  'get_canvas_state',
  'set_canvas_state',
  'add_elements',
  'clear_canvas',
  'screenshot_canvas',
  'set_screen_flow',
  // ui mock
  'get_ui_mock',
  'get_ui_viewport',
  'set_ui_mock',
  'add_ui_screen',
  'clear_ui_mock',
  // ios
  'ios_status',
  'ios_build_run',
  'ios_logs_recent',
  // memory
  'remember_note',
]);

export function mcpUrl(req: Request): string {
  // Same-origin: the MCP transport is mounted on this very server. Building
  // off the request URL means it Just Works whether we're on :3000, behind a
  // proxy, or in Electron's loopback.
  const url = new URL(req.url);
  return `${url.protocol}//${url.host}/mcp`;
}

// Pull the most recent user-authored text out of the UI message list. Each
// UIMessage's `parts` is an array of typed parts; we want the joined text
// parts of the last user message.
export function lastUserGoal(messages: UIMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== 'user') continue;
    const text = (m.parts ?? [])
      .map((p) =>
        p && (p as { type?: string }).type === 'text'
          ? (p as { text?: string }).text ?? ''
          : '',
      )
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
