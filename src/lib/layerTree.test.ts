import { describe, expect, it } from 'vitest';
import { buildRows, dropIndexFor } from './layerTree';
import type { UINode, UIScreen } from './uiMockProtocol';

const node = (id: string, group?: string): UINode => ({
  id,
  type: 'div',
  x: 0,
  y: 0,
  width: 100,
  height: 40,
  ...(group ? { group } : {}),
});

const screen = (
  nodes: UINode[],
  groups?: Array<{ id: string; name: string }>,
): UIScreen => ({
  id: 'S',
  title: 'S',
  frame: { w: 800, h: 600 },
  nodes,
  ...(groups ? { groups } : {}),
});

describe('buildRows', () => {
  it('lists ungrouped nodes top-of-z first', () => {
    const rows = buildRows(screen([node('a'), node('b'), node('c')]));
    expect(rows.map((r) => (r.kind === 'node' ? r.node.id : '?'))).toEqual([
      'c',
      'b',
      'a',
    ]);
  });

  it('collapses a group into one block at its topmost member', () => {
    // z order: a, g1, b, g2 (top). Group block anchors at g2's display slot.
    const rows = buildRows(
      screen(
        [node('a'), node('g1', 'g'), node('b'), node('g2', 'g')],
        [{ id: 'g', name: 'Pair' }],
      ),
    );
    expect(
      rows.map((r) => (r.kind === 'group' ? `group:${r.id}` : r.node.id)),
    ).toEqual(['group:g', 'b', 'a']);
    const group = rows[0];
    if (group.kind !== 'group') throw new Error('expected group row');
    expect(group.name).toBe('Pair');
    // Members listed top-of-z first too.
    expect(group.members.map((m) => m.id)).toEqual(['g2', 'g1']);
  });

  it('renders nodes with a stale group tag as plain rows', () => {
    const rows = buildRows(screen([node('a', 'ghost'), node('b')]));
    expect(rows.every((r) => r.kind === 'node')).toBe(true);
    expect(rows).toHaveLength(2);
  });
});

describe('dropIndexFor', () => {
  // Array [a, b, c, d] — z ascending, display order d, c, b, a.
  const s = screen([node('a'), node('b'), node('c'), node('d')]);

  it('above the reference = one past it (dragged from below)', () => {
    // Drag a (index 0) above c (index 2): after removal c sits at 1 → 2.
    expect(dropIndexFor(s, 'c', 'above', 'a')).toBe(2);
  });

  it('below the reference = its slot (dragged from below)', () => {
    expect(dropIndexFor(s, 'c', 'below', 'a')).toBe(1);
  });

  it('no index shift when the dragged node sits above the reference', () => {
    // Drag d (index 3) below b (index 1): b keeps index 1 → drop at 1.
    expect(dropIndexFor(s, 'b', 'below', 'd')).toBe(1);
    expect(dropIndexFor(s, 'b', 'above', 'd')).toBe(2);
  });
});
