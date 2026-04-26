import { describe, it, expect } from 'vitest';
import type { UIMessage } from 'ai';
import {
  ALLOWED_TOOLS,
  filterAllowedTools,
  lastUserGoal,
  mcpUrl,
} from './helpers';

// Helper to build a UIMessage without dragging in the AI SDK's full type machinery.
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
    expect(mcpUrl(req('http://localhost:3000/api/agent'))).toBe(
      'http://localhost:3000/mcp',
    );
  });

  it('builds a same-origin /mcp URL over https', () => {
    expect(mcpUrl(req('https://example.com/api/agent'))).toBe(
      'https://example.com/mcp',
    );
  });

  it('preserves a custom port', () => {
    expect(mcpUrl(req('http://localhost:4321/x/y/z'))).toBe(
      'http://localhost:4321/mcp',
    );
  });

  it('preserves an IPv6 host', () => {
    expect(mcpUrl(req('http://[::1]:3000/api/agent'))).toBe(
      'http://[::1]:3000/mcp',
    );
  });
});

describe('filterAllowedTools', () => {
  it('keeps the five UI/terminal tools and drops every canvas tool', () => {
    const allTools = {
      dom_inspect: { description: 'inspect' },
      cursor_move: { description: 'move' },
      cursor_click: { description: 'click' },
      cursor_type: { description: 'type' },
      terminal_type: { description: 'tt' },
      // canvas tools that must be dropped:
      get_canvas_state: { description: 'gcs' },
      set_canvas_state: { description: 'scs' },
      add_elements: { description: 'add' },
      clear_canvas: { description: 'clear' },
      screenshot_canvas: { description: 'snap' },
    };
    const filtered = filterAllowedTools(allTools);
    expect(Object.keys(filtered).sort()).toEqual([
      'cursor_click',
      'cursor_move',
      'cursor_type',
      'dom_inspect',
      'terminal_type',
    ]);
    expect('set_canvas_state' in filtered).toBe(false);
    expect('add_elements' in filtered).toBe(false);
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
    const input = { dom_inspect: 1, set_canvas_state: 2 };
    filterAllowedTools(input);
    expect(input).toEqual({ dom_inspect: 1, set_canvas_state: 2 });
  });
});

describe('ALLOWED_TOOLS', () => {
  it('contains exactly the five UI/terminal tool names', () => {
    expect([...ALLOWED_TOOLS].sort()).toEqual([
      'cursor_click',
      'cursor_move',
      'cursor_type',
      'dom_inspect',
      'terminal_type',
    ]);
  });
});
