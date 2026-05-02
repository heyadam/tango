import { describe, expect, it } from 'vitest';
import type { UISpec } from '@/lib/uiMockProtocol';
import { analyzeCanvasElements, analyzeUiSpec } from './uiMockBridge';

const screen = (overrides: Partial<UISpec['screens'][number]> = {}): UISpec['screens'][number] => ({
  id: 'home',
  title: 'Home',
  frame: { w: 360, h: 720 },
  nodes: [],
  ...overrides,
});

describe('analyzeUiSpec', () => {
  it('returns empty diagnostics for a clean spec', () => {
    const spec: UISpec = {
      screens: [
        screen({
          nodes: [
            {
              id: 'btn',
              type: 'Button',
              x: 16,
              y: 16,
              width: 120,
              height: 40,
              text: 'Sign in',
            },
          ],
        }),
      ],
    };
    expect(analyzeUiSpec(spec)).toEqual({ frameOverflows: [], emptyText: [] });
  });

  it('flags x/y overflow and negative coords', () => {
    const spec: UISpec = {
      screens: [
        screen({
          nodes: [
            {
              id: 'over-x',
              type: 'div',
              x: 200,
              y: 0,
              width: 200, // 200+200=400 > 360
              height: 40,
            },
            {
              id: 'over-y',
              type: 'div',
              x: 0,
              y: 700,
              width: 100,
              height: 50, // 700+50=750 > 720
            },
            {
              id: 'neg-x',
              type: 'div',
              x: -10,
              y: 0,
              width: 50,
              height: 50,
            },
          ],
        }),
      ],
    };
    const diag = analyzeUiSpec(spec);
    expect(diag.frameOverflows).toEqual(
      expect.arrayContaining([
        { screenId: 'home', nodeId: 'over-x', axis: 'x', overshoot: 40 },
        { screenId: 'home', nodeId: 'over-y', axis: 'y', overshoot: 30 },
        { screenId: 'home', nodeId: 'neg-x', axis: 'x', overshoot: 10 },
      ]),
    );
  });

  it('flags missing text on label-bearing types only', () => {
    const spec: UISpec = {
      screens: [
        screen({
          nodes: [
            { id: 'btn', type: 'Button', x: 0, y: 0, width: 80, height: 40 },
            { id: 'badge', type: 'Badge', x: 0, y: 50, width: 60, height: 20 },
            { id: 'h1', type: 'heading', x: 0, y: 80, width: 200, height: 32 },
            { id: 'div', type: 'div', x: 0, y: 120, width: 100, height: 100 },
            {
              id: 'input',
              type: 'Input',
              x: 0,
              y: 230,
              width: 200,
              height: 40,
            },
          ],
        }),
      ],
    };
    const diag = analyzeUiSpec(spec);
    expect(diag.emptyText.map((e) => e.nodeId).sort()).toEqual([
      'badge',
      'btn',
      'h1',
    ]);
  });

  it('treats whitespace-only text as empty', () => {
    const spec: UISpec = {
      screens: [
        screen({
          nodes: [
            {
              id: 'btn',
              type: 'Button',
              x: 0,
              y: 0,
              width: 80,
              height: 40,
              text: '   \t\n',
            },
          ],
        }),
      ],
    };
    expect(analyzeUiSpec(spec).emptyText).toHaveLength(1);
  });
});

describe('analyzeCanvasElements', () => {
  it('flags text elements with no text', () => {
    const els = [
      { type: 'text', id: 't1', text: 'hello' },
      { type: 'text', id: 't2', text: '' },
      { type: 'text', id: 't3' },
      { type: 'rectangle', id: 'r1' },
    ];
    expect(analyzeCanvasElements(els).emptyText.map((e) => e.id)).toEqual([
      't2',
      't3',
    ]);
  });

  it('returns empty diagnostics for non-text-only batches', () => {
    const els = [
      { type: 'rectangle', id: 'r1' },
      { type: 'arrow', id: 'a1' },
    ];
    expect(analyzeCanvasElements(els)).toEqual({ emptyText: [] });
  });
});
