import { describe, expect, it } from 'vitest';
import { buildWriteResult, type WriteToolResult } from './mcp';

// Contract tests for the write-tool result envelope. The 5 "write" MCP tools
// (`set_canvas_state`, `add_elements`, `set_screen_flow`, `set_ui_mock`,
// `add_ui_screen`) all share this shape so terminal-Claude can branch on
// `diagnostics.<key>.length === 0` without per-tool special cases. A future
// refactor that drops `action` or `written` would surface here before
// downstream skills go silently wrong.

describe('buildWriteResult', () => {
  it('returns ok=true with the four canonical keys', () => {
    const r = buildWriteResult({
      action: 'set_canvas_state',
      written: { elementCount: 3 },
      diagnostics: { emptyText: [] },
    });
    expect(r.ok).toBe(true);
    expect(Object.keys(r).sort()).toEqual([
      'action',
      'diagnostics',
      'ok',
      'written',
    ]);
  });

  it.each([
    'set_canvas_state',
    'add_elements',
    'set_screen_flow',
    'set_ui_mock',
    'add_ui_screen',
  ] as const)('preserves the action label %s', (action) => {
    const r = buildWriteResult({
      action,
      written: {},
      diagnostics: {},
    });
    expect(r.action).toBe(action);
  });

  it('passes the diagnostics object through verbatim', () => {
    const diagnostics = {
      frameOverflows: [
        { screenId: 'home', nodeId: 'btn', axis: 'x', overshoot: 12 },
      ],
      emptyText: [{ screenId: 'home', nodeId: 'badge', type: 'Badge' }],
    };
    const r = buildWriteResult({
      action: 'set_ui_mock',
      written: { screenCount: 1, nodeCount: 2 },
      diagnostics,
    });
    expect(r.diagnostics).toEqual(diagnostics);
  });

  it('round-trips through JSON.stringify with the same shape', () => {
    // The wire format is JSON-stringified text content; this pins that the
    // structural shape survives serialization (no Map/Set/undefined
    // shenanigans).
    const r: WriteToolResult = buildWriteResult({
      action: 'set_screen_flow',
      written: { screenCount: 5, edgeCount: 7, elementCount: 30 },
      diagnostics: { danglingEdges: [], layoutOverlaps: [] },
    });
    const restored = JSON.parse(JSON.stringify(r)) as WriteToolResult;
    expect(restored).toEqual(r);
  });
});
