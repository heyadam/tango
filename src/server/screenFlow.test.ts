import { describe, it, expect } from 'vitest';
import {
  type Edge,
  type Screen,
  layoutScreenFlow,
  safeId,
  screenFlowDiagnostics,
  screenFlowElements,
  validateScreenFlowInput,
} from './screenFlow';

const screen = (
  id: string,
  overrides: Partial<Screen> = {},
): Screen => ({
  id,
  name: id,
  kind: 'swiftui',
  ...overrides,
});

const edge = (from: string, to: string, kind: Edge['kind'] = 'push'): Edge => ({
  from,
  to,
  kind,
});

describe('layoutScreenFlow', () => {
  it('places an entry at rank 0 and its child at rank 1', () => {
    const screens = [screen('Root', { isEntry: true }), screen('Detail')];
    const layout = layoutScreenFlow(screens, [edge('Root', 'Detail')]);
    const root = layout.get('Root')!;
    const detail = layout.get('Detail')!;
    expect(root.y).toBeLessThan(detail.y);
  });

  it('places two entries side-by-side at rank 0', () => {
    const screens = [
      screen('Home', { isEntry: true }),
      screen('Search', { isEntry: true }),
    ];
    const layout = layoutScreenFlow(screens, []);
    const home = layout.get('Home')!;
    const search = layout.get('Search')!;
    expect(home.y).toBe(search.y);
    expect(home.x).not.toBe(search.x);
  });

  it('handles cycles without infinite loop', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
    ];
    const layout = layoutScreenFlow(screens, [edge('A', 'B'), edge('B', 'A')]);
    expect(layout.get('A')!.y).toBeLessThan(layout.get('B')!.y);
  });

  it('falls back to nodes with no incoming edges as entries when isEntry is unset', () => {
    const screens = [screen('Root'), screen('Child')];
    const layout = layoutScreenFlow(screens, [edge('Root', 'Child')]);
    expect(layout.get('Root')!.y).toBeLessThan(layout.get('Child')!.y);
  });

  it('falls back to alphabetically-first node for cycle-only graphs', () => {
    const screens = [screen('Z'), screen('A')];
    const layout = layoutScreenFlow(screens, [edge('A', 'Z'), edge('Z', 'A')]);
    expect(layout.get('A')!.y).toBeLessThan(layout.get('Z')!.y);
  });

  it('places orphan nodes at rank 0', () => {
    const screens = [
      screen('Root', { isEntry: true }),
      screen('Child'),
      screen('Floating'),
    ];
    const layout = layoutScreenFlow(screens, [edge('Root', 'Child')]);
    expect(layout.get('Floating')!.y).toBe(layout.get('Root')!.y);
  });

  it('is deterministic for a fixed input', () => {
    const screens = [
      screen('Beta', { isEntry: true }),
      screen('Alpha', { isEntry: true }),
      screen('Gamma'),
    ];
    const edges = [edge('Beta', 'Gamma'), edge('Alpha', 'Gamma')];
    const a = layoutScreenFlow(screens, edges);
    const b = layoutScreenFlow(screens, edges);
    for (const [id, box] of a) {
      expect(b.get(id)).toEqual(box);
    }
  });

  it('respects custom origin and gap options', () => {
    const screens = [screen('A', { isEntry: true }), screen('B')];
    const layout = layoutScreenFlow(screens, [edge('A', 'B')], {
      originX: 1000,
      originY: 2000,
      cardWidth: 100,
      cardHeight: 50,
      vGap: 30,
    });
    expect(layout.get('A')).toEqual({ x: 1000, y: 2000, w: 100, h: 50 });
    expect(layout.get('B')).toEqual({ x: 1000, y: 2080, w: 100, h: 50 });
  });

  it('skips edges referencing unknown screens during BFS without crashing', () => {
    const screens = [screen('A', { isEntry: true })];
    expect(() =>
      layoutScreenFlow(screens, [edge('A', 'Ghost'), edge('Ghost', 'B')]),
    ).not.toThrow();
  });
});

describe('screenFlowElements', () => {
  it('emits 3 elements per screen with no summary', () => {
    const screens = [screen('A', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [], layout);
    expect(els).toHaveLength(3);
    expect(els[0].type).toBe('rectangle');
    expect(els[1].type).toBe('text');
    expect(els[2].type).toBe('text');
  });

  it('adds a 4th element when a screen has a summary', () => {
    const screens = [screen('A', { isEntry: true, summary: 'Login screen' })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [], layout);
    expect(els).toHaveLength(4);
    expect((els[3] as { text?: string }).text).toBe('Login screen');
  });

  it('marks entry screens with an amber fill and thicker stroke', () => {
    const screens = [screen('Home', { isEntry: true }), screen('Other')];
    const layout = layoutScreenFlow(screens, [edge('Home', 'Other')]);
    const els = screenFlowElements(screens, [], layout);
    const homeRect = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-Home-rect',
    ) as Record<string, unknown>;
    const otherRect = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-Other-rect',
    ) as Record<string, unknown>;
    expect(homeRect.backgroundColor).toBe('#fef3c7');
    expect(homeRect.strokeWidth).toBe(2);
    expect(otherRect.backgroundColor).toBe('transparent');
    expect(otherRect.strokeWidth).toBe(1);
  });

  it('groups card elements with a shared groupId', () => {
    const screens = [screen('A', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [], layout);
    const groups = els.map((e) => (e as { groupIds?: string[] }).groupIds?.[0]);
    expect(new Set(groups).size).toBe(1);
    expect(groups[0]).toBe('flow-card-A');
  });

  it('renders an arrow per edge with bindings to card rectangles', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
    ];
    const layout = layoutScreenFlow(screens, [edge('A', 'B')]);
    const els = screenFlowElements(screens, [edge('A', 'B')], layout);
    const arrows = els.filter((e) => (e as { type?: string }).type === 'arrow');
    expect(arrows).toHaveLength(1);
    const arrow = arrows[0] as Record<string, unknown>;
    expect((arrow.startBinding as { elementId: string }).elementId).toBe(
      'flow-card-A-rect',
    );
    expect((arrow.endBinding as { elementId: string }).elementId).toBe(
      'flow-card-B-rect',
    );
  });

  it('colors arrows by edge kind', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
      screen('C'),
    ];
    const layout = layoutScreenFlow(screens, [
      edge('A', 'B', 'sheet'),
      edge('A', 'C', 'tab'),
    ]);
    const els = screenFlowElements(
      screens,
      [edge('A', 'B', 'sheet'), edge('A', 'C', 'tab')],
      layout,
    );
    const arrowAB = els.find(
      (e) => (e as { id?: string }).id === 'flow-edge-A-B-0',
    ) as Record<string, unknown>;
    const arrowAC = els.find(
      (e) => (e as { id?: string }).id === 'flow-edge-A-C-1',
    ) as Record<string, unknown>;
    expect(arrowAB.strokeColor).toBe('#2563eb');
    expect(arrowAC.strokeColor).toBe('#0d9488');
  });

  it('adds a label text element when an edge carries a label', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
    ];
    const labeled = { ...edge('A', 'B'), label: 'Sign in' };
    const layout = layoutScreenFlow(screens, [labeled]);
    const els = screenFlowElements(screens, [labeled], layout);
    const labelEl = els.find(
      (e) => (e as { id?: string }).id === 'flow-edge-A-B-0-label',
    );
    expect(labelEl).toBeDefined();
    expect((labelEl as { text?: string }).text).toBe('Sign in');
  });

  it('skips self-loop edges silently', () => {
    const screens = [screen('A', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [edge('A', 'A')], layout);
    expect(els.filter((e) => (e as { type?: string }).type === 'arrow')).toHaveLength(
      0,
    );
  });

  it('skips edges whose endpoints are missing from the layout', () => {
    const screens = [screen('A', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(
      screens,
      [edge('A', 'Ghost'), edge('Ghost', 'A')],
      layout,
    );
    expect(els.filter((e) => (e as { type?: string }).type === 'arrow')).toHaveLength(
      0,
    );
  });

  it('sanitizes screen ids with special characters into element ids', () => {
    const screens = [screen('My/View.swift', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [], layout);
    const rect = els.find(
      (e) => (e as { type?: string }).type === 'rectangle',
    ) as Record<string, unknown>;
    expect(rect.id).toBe('flow-card-My_View_swift-rect');
  });
});

describe('validateScreenFlowInput', () => {
  it('returns null for a valid graph', () => {
    expect(
      validateScreenFlowInput(
        [screen('A'), screen('B')],
        [edge('A', 'B')],
      ),
    ).toBeNull();
  });

  it('rejects duplicate screen ids', () => {
    expect(
      validateScreenFlowInput([screen('A'), screen('A')], []),
    ).toMatch(/Duplicate screen id: A/);
  });

  it('treats edges referencing unknown screens as soft (not fatal)', () => {
    expect(
      validateScreenFlowInput([screen('A')], [edge('A', 'Ghost')]),
    ).toBeNull();
  });

  it('rejects ids that collide after sanitization', () => {
    // Both ids reduce to "A_B" after safeId — Excalidraw would silently
    // overwrite one card with the other if we let this through.
    const result = validateScreenFlowInput(
      [screen('A/B'), screen('A.B')],
      [],
    );
    expect(result).toMatch(/collide after sanitization/);
  });

  it.each([
    ['A/B', 'A.B'],
    ['Foo/Bar', 'Foo Bar'],
    ['Auth!', 'Auth?'],
    ['x.y.z', 'x_y_z'],
  ])('detects sanitization collision for %s vs %s', (a, b) => {
    expect(
      validateScreenFlowInput([screen(a), screen(b)], []),
    ).toMatch(/collide after sanitization/);
  });

  it('collects multiple fatal errors into one joined message', () => {
    const result = validateScreenFlowInput(
      [screen('A'), screen('A'), screen('B/x'), screen('B.x')],
      [],
    );
    expect(result).toMatch(/2 validation errors/);
    expect(result).toMatch(/Duplicate screen id: A/);
    expect(result).toMatch(/collide after sanitization/);
  });
});

describe('screenFlowDiagnostics', () => {
  it('returns empty arrays for a clean graph', () => {
    const screens = [screen('A', { isEntry: true }), screen('B')];
    const edges = [edge('A', 'B')];
    const layout = layoutScreenFlow(screens, edges);
    const diag = screenFlowDiagnostics(screens, edges, layout);
    expect(diag.danglingEdges).toEqual([]);
    expect(diag.layoutOverlaps).toEqual([]);
  });

  it('flags edges with unknown endpoints', () => {
    const screens = [screen('A')];
    const edges = [edge('A', 'Ghost'), edge('Phantom', 'A')];
    const layout = layoutScreenFlow(screens, edges);
    const diag = screenFlowDiagnostics(screens, edges, layout);
    expect(diag.danglingEdges).toEqual([
      { from: 'A', to: 'Ghost', reason: 'unknown_to' },
      { from: 'Phantom', to: 'A', reason: 'unknown_from' },
    ]);
  });

  it('flags self-loops', () => {
    const screens = [screen('A')];
    const edges = [edge('A', 'A')];
    const layout = layoutScreenFlow(screens, edges);
    const diag = screenFlowDiagnostics(screens, edges, layout);
    expect(diag.danglingEdges).toEqual([
      { from: 'A', to: 'A', reason: 'self_loop' },
    ]);
  });

  it('detects bounding-box overlaps', () => {
    const screens = [screen('A'), screen('B')];
    const layout = new Map([
      ['A', { x: 0, y: 0, w: 100, h: 100 }],
      ['B', { x: 50, y: 50, w: 100, h: 100 }],
    ]);
    const diag = screenFlowDiagnostics(screens, [], layout);
    expect(diag.layoutOverlaps).toEqual([{ a: 'A', b: 'B' }]);
  });

  it('treats touching boxes as non-overlapping', () => {
    const screens = [screen('A'), screen('B')];
    const layout = new Map([
      ['A', { x: 0, y: 0, w: 100, h: 100 }],
      ['B', { x: 100, y: 0, w: 100, h: 100 }],
    ]);
    const diag = screenFlowDiagnostics(screens, [], layout);
    expect(diag.layoutOverlaps).toEqual([]);
  });
});

describe('safeId', () => {
  it('replaces non-alphanumeric chars with underscores', () => {
    expect(safeId('My/View.swift')).toBe('My_View_swift');
    expect(safeId('Auth Screen!')).toBe('Auth_Screen_');
  });

  it('preserves valid id characters', () => {
    expect(safeId('AuthView_2')).toBe('AuthView_2');
    expect(safeId('detail-view')).toBe('detail-view');
  });
});

describe('screenFlowElements — boundElements + ordering', () => {
  it('writes boundElements back-references on rectangles that have arrows', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
    ];
    const layout = layoutScreenFlow(screens, [edge('A', 'B')]);
    const els = screenFlowElements(screens, [edge('A', 'B')], layout);
    const rectA = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-A-rect',
    ) as Record<string, unknown>;
    const rectB = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-B-rect',
    ) as Record<string, unknown>;
    expect(rectA.boundElements).toEqual([
      { type: 'arrow', id: 'flow-edge-A-B-0' },
    ]);
    expect(rectB.boundElements).toEqual([
      { type: 'arrow', id: 'flow-edge-A-B-0' },
    ]);
  });

  it('omits boundElements field when no arrows touch a card', () => {
    const screens = [screen('Lonely', { isEntry: true })];
    const layout = layoutScreenFlow(screens, []);
    const els = screenFlowElements(screens, [], layout);
    const rect = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-Lonely-rect',
    ) as Record<string, unknown>;
    expect(rect.boundElements).toBeUndefined();
  });

  it('produces identical arrow ids for the same edges in different input orders', () => {
    const screens = [
      screen('A', { isEntry: true }),
      screen('B'),
      screen('C'),
    ];
    const layout = layoutScreenFlow(screens, []);
    const ordered = [edge('A', 'B', 'sheet'), edge('A', 'C', 'tab')];
    const reversed = [edge('A', 'C', 'tab'), edge('A', 'B', 'sheet')];
    const a = screenFlowElements(screens, ordered, layout)
      .filter((e) => (e as { type?: string }).type === 'arrow')
      .map((e) => (e as { id: string }).id)
      .sort();
    const b = screenFlowElements(screens, reversed, layout)
      .filter((e) => (e as { type?: string }).type === 'arrow')
      .map((e) => (e as { id: string }).id)
      .sort();
    expect(a).toEqual(b);
  });

  it('clamps summary text height when cardHeight is small', () => {
    const screens = [screen('A', { isEntry: true, summary: 'Small' })];
    const layout = layoutScreenFlow(screens, [], { cardHeight: 80 });
    const els = screenFlowElements(screens, [], layout);
    const summary = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-A-summary',
    ) as Record<string, unknown>;
    // 80 - 12 - 64 = 4, would have been a 4-px-high text box; clamp to 20.
    expect(summary.height).toBe(20);
  });

  it('orders cards alphabetically within a rank', () => {
    const screens = [
      screen('Root', { isEntry: true }),
      screen('Charlie'),
      screen('Alpha'),
      screen('Bravo'),
    ];
    const layout = layoutScreenFlow(screens, [
      edge('Root', 'Charlie'),
      edge('Root', 'Alpha'),
      edge('Root', 'Bravo'),
    ]);
    // All three children should be at the same y; their x should be in
    // alphabetical order: Alpha < Bravo < Charlie.
    const alpha = layout.get('Alpha')!;
    const bravo = layout.get('Bravo')!;
    const charlie = layout.get('Charlie')!;
    expect(alpha.y).toBe(bravo.y);
    expect(bravo.y).toBe(charlie.y);
    expect(alpha.x).toBeLessThan(bravo.x);
    expect(bravo.x).toBeLessThan(charlie.x);
  });

  it('groups multiple arrows touching the same rectangle into a single boundElements list', () => {
    const screens = [
      screen('Hub', { isEntry: true }),
      screen('A'),
      screen('B'),
    ];
    const layout = layoutScreenFlow(screens, [
      edge('Hub', 'A'),
      edge('Hub', 'B'),
    ]);
    const els = screenFlowElements(
      screens,
      [edge('Hub', 'A'), edge('Hub', 'B')],
      layout,
    );
    const hubRect = els.find(
      (e) => (e as { id?: string }).id === 'flow-card-Hub-rect',
    ) as Record<string, unknown>;
    const bound = hubRect.boundElements as Array<{ type: string; id: string }>;
    expect(bound).toHaveLength(2);
    expect(bound.every((b) => b.type === 'arrow')).toBe(true);
  });
});
