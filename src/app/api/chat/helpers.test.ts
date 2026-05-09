import { describe, it, expect } from 'vitest';
import type { UIMessage } from 'ai';
import {
  ALLOWED_TOOLS,
  filterAllowedTools,
  lastUserGoal,
  mcpUrl,
} from './helpers';

function userMsg(...texts: string[]): UIMessage {
  return {
    id: Math.random().toString(36).slice(2),
    role: 'user',
    parts: texts.map((t) => ({ type: 'text' as const, text: t })),
  } as unknown as UIMessage;
}
function asstMsg(text: string): UIMessage {
  return {
    id: Math.random().toString(36).slice(2),
    role: 'assistant',
    parts: [{ type: 'text' as const, text }],
  } as unknown as UIMessage;
}

describe('lastUserGoal', () => {
  it('returns "" for an empty list', () => {
    expect(lastUserGoal([])).toBe('');
  });

  it('returns "" when only assistant messages are present', () => {
    expect(lastUserGoal([asstMsg('hi')])).toBe('');
  });

  it('returns the text of the most recent user message', () => {
    const msgs = [userMsg('first'), asstMsg('reply'), userMsg('latest')];
    expect(lastUserGoal(msgs)).toBe('latest');
  });

  it('joins multiple text parts with a single space and trims', () => {
    const msgs = [userMsg(' hello ', ' world ')];
    expect(lastUserGoal(msgs)).toBe('hello   world');
  });

  it('falls through to the next-newer user message when the most recent has no text parts', () => {
    const empty = {
      id: '1',
      role: 'user',
      parts: [{ type: 'image' as const, url: 'x' }],
    } as unknown as UIMessage;
    const msgs = [userMsg('older'), empty];
    expect(lastUserGoal(msgs)).toBe('older');
  });

  it('handles missing parts array gracefully', () => {
    const noParts = { id: '1', role: 'user' } as unknown as UIMessage;
    expect(lastUserGoal([noParts])).toBe('');
  });
});

describe('mcpUrl', () => {
  function req(url: string): Request {
    return { url } as Request;
  }

  it('builds a same-origin /mcp URL over http', () => {
    expect(mcpUrl(req('http://localhost:3000/api/chat'))).toBe(
      'http://localhost:3000/mcp',
    );
  });

  it('builds a same-origin /mcp URL over https', () => {
    expect(mcpUrl(req('https://example.com/api/chat'))).toBe(
      'https://example.com/mcp',
    );
  });

  it('preserves a custom port', () => {
    expect(mcpUrl(req('http://localhost:4321/x/y/z'))).toBe(
      'http://localhost:4321/mcp',
    );
  });

  it('preserves an IPv6 host', () => {
    expect(mcpUrl(req('http://[::1]:3000/api/chat'))).toBe(
      'http://[::1]:3000/mcp',
    );
  });
});

describe('filterAllowedTools', () => {
  it('keeps every brain-side MCP tool and drops the legacy cursor/terminal tools', () => {
    const allTools = {
      // chat-allowlisted:
      get_canvas_state: { description: '' },
      set_canvas_state: { description: '' },
      add_elements: { description: '' },
      clear_canvas: { description: '' },
      screenshot_canvas: { description: '' },
      set_screen_flow: { description: '' },
      get_ui_mock: { description: '' },
      get_ui_viewport: { description: '' },
      set_ui_mock: { description: '' },
      add_ui_screen: { description: '' },
      clear_ui_mock: { description: '' },
      ios_status: { description: '' },
      ios_build_run: { description: '' },
      ios_logs_recent: { description: '' },
      remember_note: { description: '' },
      // legacy controller-agent tools that must be dropped:
      dom_inspect: { description: '' },
      cursor_move: { description: '' },
      cursor_click: { description: '' },
      cursor_type: { description: '' },
      terminal_type: { description: '' },
    };
    const filtered = filterAllowedTools(allTools);
    expect(Object.keys(filtered).sort()).toEqual([...ALLOWED_TOOLS].sort());
    expect('terminal_type' in filtered).toBe(false);
    expect('dom_inspect' in filtered).toBe(false);
  });

  it('returns {} for empty input', () => {
    expect(filterAllowedTools({})).toEqual({});
  });

  it('honors a custom allowed-set argument', () => {
    const out = filterAllowedTools(
      { a: 1, b: 2, c: 3 },
      new Set(['a', 'c']),
    );
    expect(out).toEqual({ a: 1, c: 3 });
  });

  it('does not mutate the input object', () => {
    const input = { get_canvas_state: 1, terminal_type: 2 };
    filterAllowedTools(input);
    expect(input).toEqual({ get_canvas_state: 1, terminal_type: 2 });
  });
});

describe('ALLOWED_TOOLS', () => {
  it('contains the 15 brain-side tool names', () => {
    expect([...ALLOWED_TOOLS].sort()).toEqual(
      [
        'add_elements',
        'add_ui_screen',
        'clear_canvas',
        'clear_ui_mock',
        'get_canvas_state',
        'get_ui_mock',
        'get_ui_viewport',
        'ios_build_run',
        'ios_logs_recent',
        'ios_status',
        'remember_note',
        'screenshot_canvas',
        'set_canvas_state',
        'set_screen_flow',
        'set_ui_mock',
      ].sort(),
    );
  });

  it('does not contain any cursor/terminal puppet tools', () => {
    for (const banned of [
      'dom_inspect',
      'cursor_move',
      'cursor_click',
      'cursor_type',
      'terminal_type',
    ]) {
      expect(ALLOWED_TOOLS.has(banned)).toBe(false);
    }
  });
});
