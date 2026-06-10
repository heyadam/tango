import { describe, expect, it } from 'vitest';
import {
  buildRows,
  dropIndexFor,
  endDropIndex,
  groupDropIndexFor,
  groupEndDropIndex,
} from './layerTree';
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

  it('no removal adjustment when the dragged node lives on another screen', () => {
    // Cross-screen drag: the dragged node is not in this array, so removal
    // never shifts these indices.
    expect(dropIndexFor(s, 'c', 'above', 'zz')).toBe(3);
    expect(dropIndexFor(s, 'c', 'below', 'zz')).toBe(2);
  });
});

describe('endDropIndex', () => {
  const s = screen([node('a'), node('b'), node('c')]);

  it('drops at the end, adjusted for a dragged node on this screen', () => {
    expect(endDropIndex(s, 'a')).toBe(2);
  });

  it('drops at the raw end for a cross-screen drag', () => {
    expect(endDropIndex(s, 'zz')).toBe(3);
  });
});

describe('groupEndDropIndex', () => {
  const s = screen(
    [node('a'), node('g1', 'g'), node('g2', 'g'), node('b')],
    [{ id: 'g', name: 'Pair' }],
  );

  it('subtracts the dragged group members on a same-screen drag', () => {
    expect(groupEndDropIndex(s, 'g', 'S')).toBe(2);
  });

  it('drops at the raw end when the group lives on another screen', () => {
    expect(groupEndDropIndex(s, 'other', 'T')).toBe(4);
  });

  it('does not subtract a same-id group owned by the target on a cross-screen drag', () => {
    // 'g' exists on BOTH screens: the dragged group (from T) is a distinct
    // group, so S's members are not being removed — raw end.
    expect(groupEndDropIndex(s, 'g', 'T')).toBe(4);
  });
});

describe('groupDropIndexFor', () => {
  // Array [g1, a, g2, b] — group g fractured around a to exercise the
  // members-below count; display order b, g-block, a.
  const s = screen(
    [node('g1', 'g'), node('a'), node('g2', 'g'), node('b')],
    [{ id: 'g', name: 'Pair' }],
  );

  it('counts only members below the reference on a same-screen drag', () => {
    // ref a (index 1): one member (g1) below → afterRemoval 0.
    expect(groupDropIndexFor(s, 'a', 'below', 'g', 'S')).toBe(0);
    expect(groupDropIndexFor(s, 'a', 'above', 'g', 'S')).toBe(1);
    // ref b (index 3): both members below → afterRemoval 1.
    expect(groupDropIndexFor(s, 'b', 'below', 'g', 'S')).toBe(1);
    expect(groupDropIndexFor(s, 'b', 'above', 'g', 'S')).toBe(2);
  });

  it('returns null when the reference is a member of the dragged group', () => {
    expect(groupDropIndexFor(s, 'g1', 'above', 'g', 'S')).toBeNull();
    expect(groupDropIndexFor(s, 'g2', 'below', 'g', 'S')).toBeNull();
  });

  it('returns null when the reference is not on this screen', () => {
    expect(groupDropIndexFor(s, 'zz', 'above', 'g', 'S')).toBeNull();
    expect(groupDropIndexFor(s, 'zz', 'above', 'g', 'T')).toBeNull();
  });

  it('applies no adjustment when the group lives on another screen', () => {
    // No members of 'other' here, and fromScreenId differs anyway.
    expect(groupDropIndexFor(s, 'g2', 'below', 'other', 'T')).toBe(2);
    expect(groupDropIndexFor(s, 'g2', 'above', 'other', 'T')).toBe(3);
  });

  it('treats a same-id group owned by the target as ordinary nodes on a cross-screen drag', () => {
    // Dragging 'g' from screen T: S's 'g' is a DIFFERENT group that is not
    // being removed — its members are legal refs and never subtracted.
    expect(groupDropIndexFor(s, 'g1', 'above', 'g', 'T')).toBe(1);
    expect(groupDropIndexFor(s, 'b', 'below', 'g', 'T')).toBe(3);
    expect(groupDropIndexFor(s, 'b', 'above', 'g', 'T')).toBe(4);
  });
});
