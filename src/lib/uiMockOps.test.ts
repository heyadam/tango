import { describe, expect, it } from 'vitest';
import {
  addNodesToScreen,
  adoptSnapshotSpec,
  appendScreenToSpec,
  applyComponentToSpec,
  carryLibraryForward,
  describeDesignLibrary,
  describeLayers,
  duplicateScreenInSpec,
  findNodeInSpec,
  groupNodesInSpec,
  instantiateComponentInSpec,
  moveGroupInSpec,
  moveNodeInSpec,
  normalizeScreenGroups,
  removeNodesFromSpec,
  removeScreenFromSpec,
  renameGroupInSpec,
  reorderNodeInSpec,
  ungroupNodesInSpec,
  updateNodeInSpec,
  updateNodesInSpec,
  updateScreenInSpec,
  validateComponentList,
} from './uiMockOps';
import type {
  UIComponent,
  UINode,
  UIScreen,
  UISpec,
} from './uiMockProtocol';

const node = (id: string, overrides: Partial<UINode> = {}): UINode => ({
  id,
  type: 'div',
  x: 0,
  y: 0,
  width: 100,
  height: 40,
  ...overrides,
});

const screen = (id: string, nodes: UINode[] = []): UIScreen => ({
  id,
  title: id,
  frame: { w: 800, h: 600 },
  nodes,
});

const spec = (screens: UIScreen[]): UISpec => ({ screens });

// A two-screen fixture: A has [a1, a2, a3] (a3 on top), B has [b1].
const fixture = (): UISpec =>
  spec([
    screen('A', [node('a1'), node('a2'), node('a3')]),
    screen('B', [node('b1')]),
  ]);

describe('addNodesToScreen', () => {
  it('appends nodes at the top of z-order', () => {
    const out = addNodesToScreen(fixture(), 'A', [node('a4'), node('a5')]);
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual([
      'a1',
      'a2',
      'a3',
      'a4',
      'a5',
    ]);
  });

  it('does not mutate the input spec', () => {
    const input = fixture();
    addNodesToScreen(input, 'A', [node('a4')]);
    expect(input.screens[0].nodes).toHaveLength(3);
  });

  it('throws on unknown screen id', () => {
    expect(() => addNodesToScreen(fixture(), 'Z', [node('z1')])).toThrow(
      /Unknown screen id: Z/,
    );
  });

  it('throws on id collision with an existing node', () => {
    expect(() => addNodesToScreen(fixture(), 'A', [node('b1')])).toThrow(
      /already exists/,
    );
  });

  it('throws on duplicate ids within the batch', () => {
    expect(() =>
      addNodesToScreen(fixture(), 'A', [node('x'), node('x')]),
    ).toThrow(/Duplicate node id within batch: x/);
  });

  it('collects multiple errors into one message', () => {
    expect(() =>
      addNodesToScreen(fixture(), 'Z', [node('a1'), node('a1')]),
    ).toThrow(/errors:/);
  });
});

describe('appendScreenToSpec', () => {
  it('appends the screen and preserves identity of pre-existing screens', () => {
    const input = fixture();
    const incoming = screen('C', [node('c1')]);
    const out = appendScreenToSpec(input, incoming);
    expect(out.screens.map((s) => s.id)).toEqual(['A', 'B', 'C']);
    expect(out.screens[0]).toBe(input.screens[0]);
    expect(out.screens[1]).toBe(input.screens[1]);
    expect(out.screens[2]).toBe(incoming);
  });

  it('does not mutate the input spec', () => {
    const input = fixture();
    appendScreenToSpec(input, screen('C', [node('c1')]));
    expect(input.screens).toHaveLength(2);
  });

  it('rejects a duplicate screen id', () => {
    expect(() => appendScreenToSpec(fixture(), screen('A'))).toThrow(
      /Screen id already exists: A/,
    );
  });

  it('rejects a node id duplicated within the incoming screen', () => {
    expect(() =>
      appendScreenToSpec(fixture(), screen('C', [node('c1'), node('c1')])),
    ).toThrow(/Duplicate node id within screen: c1/);
  });

  it('rejects a node id colliding with an existing node', () => {
    expect(() =>
      appendScreenToSpec(fixture(), screen('C', [node('b1')])),
    ).toThrow(/Node id already exists in the mock: b1/);
  });

  it('collects ALL errors into one throw', () => {
    let message = '';
    try {
      appendScreenToSpec(fixture(), screen('A', [node('a1'), node('a1')]));
    } catch (err) {
      message = (err as Error).message;
    }
    expect(message).toMatch(/errors:/);
    expect(message).toMatch(/Screen id already exists: A/);
    expect(message).toMatch(/Duplicate node id within screen: a1/);
    expect(message).toMatch(/Node id already exists in the mock: a1/);
  });
});

describe('removeScreenFromSpec', () => {
  it('throws on an unknown screen id', () => {
    expect(() => removeScreenFromSpec(fixture(), 'Z')).toThrow(
      /Unknown screen id: Z/,
    );
  });

  it('removes only the target and keeps survivor identity', () => {
    const input = fixture();
    const out = removeScreenFromSpec(input, 'A');
    expect(out.screens.map((s) => s.id)).toEqual(['B']);
    expect(out.screens[0]).toBe(input.screens[1]);
  });

  it('does not mutate the input spec', () => {
    const input = fixture();
    removeScreenFromSpec(input, 'B');
    expect(input.screens).toHaveLength(2);
  });
});

describe('duplicateScreenInSpec', () => {
  it('appends a copy with remapped node ids and keeps other screens by identity', () => {
    const input = spec([
      screen('login', [node('login-title'), node('cta')]),
      screen('B', [node('b1')]),
    ]);
    const out = duplicateScreenInSpec(input, 'login', 'login-v1', 'Login · v1');
    expect(out.screens.map((s) => s.id)).toEqual(['login', 'B', 'login-v1']);
    const copy = out.screens[2];
    expect(copy.title).toBe('Login · v1');
    expect(copy.frame).toEqual(input.screens[0].frame);
    // prefix swap for screen-prefixed ids, prepend for the rest
    expect(copy.nodes.map((n) => n.id)).toEqual(['login-v1-title', 'login-v1-cta']);
    expect(out.screens[0]).toBe(input.screens[0]);
    expect(out.screens[1]).toBe(input.screens[1]);
  });

  it('defaults the title and drops sourceFile', () => {
    const input = spec([
      { ...screen('A', [node('a1')]), sourceFile: 'MyApp/A.swift' },
    ]);
    const out = duplicateScreenInSpec(input, 'A', 'A-v1');
    expect(out.screens[1].title).toBe('A copy');
    expect('sourceFile' in out.screens[1]).toBe(false);
  });

  it('collects all id collisions in one throw', () => {
    const input = spec([
      screen('A', [node('a1')]),
      screen('A-v1', [node('A-v1-a1')]),
    ]);
    let message = '';
    try {
      duplicateScreenInSpec(input, 'A', 'A-v1');
    } catch (err) {
      message = (err as Error).message;
    }
    expect(message).toMatch(/Screen id already exists: A-v1/);
  });

  it('throws when a remapped node id already exists elsewhere', () => {
    const input = spec([
      screen('A', [node('a1')]),
      screen('B', [node('A-v1-a1')]),
    ]);
    expect(() => duplicateScreenInSpec(input, 'A', 'A-v1')).toThrow(
      /Node id already exists in the mock: A-v1-a1/,
    );
  });

  it('throws on an unknown source screen', () => {
    expect(() => duplicateScreenInSpec(fixture(), 'Z', 'Z-v1')).toThrow(
      /Unknown screen id: Z/,
    );
  });
});

describe('updateNodesInSpec', () => {
  it('applies bulk patches and preserves untouched screen/node identity', () => {
    const input = fixture();
    const out = updateNodesInSpec(input, [
      { nodeId: 'a1', patch: { x: 10 } },
      { nodeId: 'a3', patch: { text: 'hi' } },
    ]);
    expect(out.screens[0].nodes[0]).toMatchObject({ id: 'a1', x: 10 });
    expect(out.screens[0].nodes[2]).toMatchObject({ id: 'a3', text: 'hi' });
    // untouched node keeps identity; untouched screen keeps identity
    expect(out.screens[0].nodes[1]).toBe(input.screens[0].nodes[1]);
    expect(out.screens[1]).toBe(input.screens[1]);
  });

  it('merges multiple patches to the same node in order', () => {
    const out = updateNodesInSpec(fixture(), [
      { nodeId: 'a1', patch: { x: 10, y: 5 } },
      { nodeId: 'a1', patch: { x: 99 } },
    ]);
    expect(out.screens[0].nodes[0]).toMatchObject({ x: 99, y: 5 });
  });

  it('is all-or-nothing on unknown ids, listing each once', () => {
    let message = '';
    try {
      updateNodesInSpec(fixture(), [
        { nodeId: 'nope', patch: { x: 1 } },
        { nodeId: 'nope', patch: { y: 2 } },
        { nodeId: 'a1', patch: { x: 1 } },
      ]);
    } catch (err) {
      message = (err as Error).message;
    }
    expect(message).toMatch(/Unknown node id: nope/);
    expect(message.match(/nope/g)).toHaveLength(1);
  });

  it('never lets a patch overwrite the id', () => {
    const out = updateNodesInSpec(fixture(), [
      // @ts-expect-error — id is excluded from NodePatch; guard is defensive.
      { nodeId: 'a2', patch: { id: 'hacked' } },
    ]);
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a2', 'a3']);
  });
});

describe('updateScreenInSpec', () => {
  it('patches title and frame, preserving nodes and other screens by identity', () => {
    const input = fixture();
    const out = updateScreenInSpec(input, 'A', {
      title: 'Renamed',
      frame: { w: 390, h: 844 },
    });
    expect(out.screens[0].title).toBe('Renamed');
    expect(out.screens[0].frame).toEqual({ w: 390, h: 844 });
    expect(out.screens[0].nodes).toBe(input.screens[0].nodes);
    expect(out.screens[1]).toBe(input.screens[1]);
  });

  it('leaves omitted fields unchanged', () => {
    const out = updateScreenInSpec(fixture(), 'A', { title: 'Only title' });
    expect(out.screens[0].frame).toEqual({ w: 800, h: 600 });
  });

  it('throws on an unknown screen id', () => {
    expect(() => updateScreenInSpec(fixture(), 'Z', { title: 'x' })).toThrow(
      /Unknown screen id: Z/,
    );
  });
});

describe('updateNodeInSpec', () => {
  it('shallow-merges the patch and preserves siblings', () => {
    const out = updateNodeInSpec(fixture(), 'a2', { x: 50, text: 'hi' });
    const a2 = out.screens[0].nodes.find((n) => n.id === 'a2');
    expect(a2).toMatchObject({ id: 'a2', x: 50, text: 'hi', width: 100 });
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a2', 'a3']);
  });

  it('never lets the patch overwrite the id', () => {
    const out = updateNodeInSpec(fixture(), 'a2', {
      // @ts-expect-error — id is excluded from NodePatch; guard is defensive.
      id: 'hacked',
    });
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a2', 'a3']);
  });

  it('throws on unknown node id', () => {
    expect(() => updateNodeInSpec(fixture(), 'nope', { x: 1 })).toThrow(
      /Unknown node id: nope/,
    );
  });

  it('does not mutate the input spec', () => {
    const input = fixture();
    updateNodeInSpec(input, 'a2', { x: 999 });
    expect(input.screens[0].nodes[1].x).toBe(0);
  });
});

describe('removeNodesFromSpec', () => {
  it('drops the given nodes', () => {
    const out = removeNodesFromSpec(fixture(), ['a2', 'b1']);
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a3']);
    expect(out.screens[1].nodes).toHaveLength(0);
  });

  it('is all-or-nothing: throws and mutates nothing when an id is missing', () => {
    const input = fixture();
    expect(() => removeNodesFromSpec(input, ['a1', 'nope'])).toThrow(
      /Unknown node id: nope/,
    );
    expect(input.screens[0].nodes).toHaveLength(3);
  });
});

describe('reorderNodeInSpec', () => {
  const ids = (s: UISpec) => s.screens[0].nodes.map((n) => n.id);

  it('front moves to the end (top)', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a1', 'front'))).toEqual([
      'a2',
      'a3',
      'a1',
    ]);
  });

  it('back moves to index 0 (bottom)', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a3', 'back'))).toEqual([
      'a3',
      'a1',
      'a2',
    ]);
  });

  it('forward swaps with the next sibling', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a1', 'forward'))).toEqual([
      'a2',
      'a1',
      'a3',
    ]);
  });

  it('backward swaps with the previous sibling', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a3', 'backward'))).toEqual([
      'a1',
      'a3',
      'a2',
    ]);
  });

  it('forward at the top is a no-op', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a3', 'forward'))).toEqual([
      'a1',
      'a2',
      'a3',
    ]);
  });

  it('backward at the bottom is a no-op', () => {
    expect(ids(reorderNodeInSpec(fixture(), 'a1', 'backward'))).toEqual([
      'a1',
      'a2',
      'a3',
    ]);
  });

  it('throws on unknown node id', () => {
    expect(() => reorderNodeInSpec(fixture(), 'nope', 'front')).toThrow(
      /Unknown node id: nope/,
    );
  });
});

describe('reorderNodeInSpec with groups', () => {
  const ids = (s: UISpec) => s.screens[0].nodes.map((n) => n.id);
  const withGroups = (
    nodes: UINode[],
    groups: Array<{ id: string; name: string }>,
  ): UISpec => spec([{ ...screen('A', nodes), groups }]);

  it('forward jumps an ungrouped node past the whole block above', () => {
    const input = withGroups(
      [node('x'), node('g1', { group: 'g' }), node('g2', { group: 'g' })],
      [{ id: 'g', name: 'Pair' }],
    );
    expect(ids(reorderNodeInSpec(input, 'x', 'forward'))).toEqual([
      'g1',
      'g2',
      'x',
    ]);
  });

  it('backward jumps an ungrouped node below the whole block beneath', () => {
    const input = withGroups(
      [node('g1', { group: 'g' }), node('g2', { group: 'g' }), node('x')],
      [{ id: 'g', name: 'Pair' }],
    );
    expect(ids(reorderNodeInSpec(input, 'x', 'backward'))).toEqual([
      'x',
      'g1',
      'g2',
    ]);
  });

  it('jumps a single-member block like any other', () => {
    const input = withGroups(
      [node('x'), node('g1', { group: 'g' })],
      [{ id: 'g', name: 'Solo' }],
    );
    expect(ids(reorderNodeInSpec(input, 'x', 'forward'))).toEqual(['g1', 'x']);
  });

  it('jumps exactly one block per call across adjacent blocks', () => {
    const input = withGroups(
      [
        node('x'),
        node('p1', { group: 'p' }),
        node('p2', { group: 'p' }),
        node('q1', { group: 'q' }),
        node('q2', { group: 'q' }),
      ],
      [
        { id: 'p', name: 'P' },
        { id: 'q', name: 'Q' },
      ],
    );
    const once = reorderNodeInSpec(input, 'x', 'forward');
    expect(ids(once)).toEqual(['p1', 'p2', 'x', 'q1', 'q2']);
    const twice = reorderNodeInSpec(once, 'x', 'forward');
    expect(ids(twice)).toEqual(['p1', 'p2', 'q1', 'q2', 'x']);
    // And one block per call on the way back down.
    const back = reorderNodeInSpec(twice, 'x', 'backward');
    expect(ids(back)).toEqual(['p1', 'p2', 'x', 'q1', 'q2']);
  });

  it('keeps an ungrouped node at the array edge a no-op', () => {
    const input = withGroups(
      [node('g1', { group: 'g' }), node('g2', { group: 'g' }), node('x')],
      [{ id: 'g', name: 'Pair' }],
    );
    const out = reorderNodeInSpec(input, 'x', 'forward');
    expect(ids(out)).toEqual(['g1', 'g2', 'x']);
    expect(out).not.toBe(input);
  });

  it('front/back take an ungrouped node to the array extremes', () => {
    const input = withGroups(
      [
        node('x'),
        node('g1', { group: 'g' }),
        node('g2', { group: 'g' }),
        node('y'),
      ],
      [{ id: 'g', name: 'Pair' }],
    );
    expect(ids(reorderNodeInSpec(input, 'x', 'front'))).toEqual([
      'g1',
      'g2',
      'y',
      'x',
    ]);
    expect(ids(reorderNodeInSpec(input, 'y', 'back'))).toEqual([
      'y',
      'x',
      'g1',
      'g2',
    ]);
  });

  const trio = () =>
    withGroups(
      [
        node('u'),
        node('g1', { group: 'g' }),
        node('g2', { group: 'g' }),
        node('g3', { group: 'g' }),
        node('v'),
      ],
      [{ id: 'g', name: 'Trio' }],
    );

  it('steps a member one slot within its own block', () => {
    expect(ids(reorderNodeInSpec(trio(), 'g1', 'forward'))).toEqual([
      'u',
      'g2',
      'g1',
      'g3',
      'v',
    ]);
    expect(ids(reorderNodeInSpec(trio(), 'g2', 'backward'))).toEqual([
      'u',
      'g2',
      'g1',
      'g3',
      'v',
    ]);
  });

  it('clamps member steps at the block edges (no-op, fresh spec)', () => {
    const base = trio();
    const top = reorderNodeInSpec(base, 'g3', 'forward');
    expect(ids(top)).toEqual(ids(base));
    expect(top).not.toBe(base);
    const bottom = reorderNodeInSpec(base, 'g1', 'backward');
    expect(ids(bottom)).toEqual(ids(base));
  });

  it('front/back move a member to the top/bottom of its own block only', () => {
    expect(ids(reorderNodeInSpec(trio(), 'g1', 'front'))).toEqual([
      'u',
      'g2',
      'g3',
      'g1',
      'v',
    ]);
    expect(ids(reorderNodeInSpec(trio(), 'g3', 'back'))).toEqual([
      'u',
      'g3',
      'g1',
      'g2',
      'v',
    ]);
  });

  it('treats an orphan group tag as ungrouped (normalize strips it)', () => {
    const input = spec([
      screen('A', [node('a'), node('x', { group: 'ghost' }), node('b')]),
    ]);
    const out = reorderNodeInSpec(input, 'x', 'forward');
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a', 'b', 'x']);
    expect(out.screens[0].nodes.every((n) => n.group === undefined)).toBe(true);
  });

  it('treats an orphan-tagged neighbor as ungrouped (plain swap)', () => {
    const input = spec([
      screen('A', [node('x'), node('a', { group: 'ghost' }), node('b')]),
    ]);
    const out = reorderNodeInSpec(input, 'x', 'forward');
    expect(out.screens[0].nodes.map((n) => n.id)).toEqual(['a', 'x', 'b']);
  });
});

describe('describeLayers', () => {
  it('returns z-ordered layers per screen', () => {
    const out = describeLayers(fixture());
    expect(out.screens).toHaveLength(2);
    expect(out.screens[0].layers.map((l) => [l.z, l.id])).toEqual([
      [0, 'a1'],
      [1, 'a2'],
      [2, 'a3'],
    ]);
    expect(out.screens[0].layers[0].rect).toEqual({
      x: 0,
      y: 0,
      width: 100,
      height: 40,
    });
  });

  it('scopes to one screen when screenId is given', () => {
    const out = describeLayers(fixture(), 'B');
    expect(out.screens.map((s) => s.id)).toEqual(['B']);
  });

  it('returns no screens for an unknown screenId', () => {
    expect(describeLayers(fixture(), 'Z').screens).toEqual([]);
  });

  it('truncates long text', () => {
    const long = 'x'.repeat(60);
    const out = describeLayers(spec([screen('A', [node('a1', { text: long })])]));
    expect(out.screens[0].layers[0].text!.length).toBeLessThanOrEqual(40);
    expect(out.screens[0].layers[0].text!.endsWith('…')).toBe(true);
  });

  it('passes sourceFile through when present and omits it when absent', () => {
    const withSource: UIScreen = {
      ...screen('A', [node('a1')]),
      sourceFile: 'MyApp/LoginView.swift',
    };
    const out = describeLayers(spec([withSource, screen('B', [node('b1')])]));
    expect(out.screens[0].sourceFile).toBe('MyApp/LoginView.swift');
    expect('sourceFile' in out.screens[1]).toBe(false);
  });
});

describe('groupNodesInSpec', () => {
  it('tags members, registers the group, and makes members z-contiguous', () => {
    // a1 and a3 grouped: block lands where a3 (topmost member) sat.
    const next = groupNodesInSpec(fixture(), 'A', ['a1', 'a3']);
    const a = next.screens[0];
    expect(a.nodes.map((n) => n.id)).toEqual(['a2', 'a1', 'a3']);
    expect(a.nodes.find((n) => n.id === 'a1')!.group).toBe('group-1');
    expect(a.nodes.find((n) => n.id === 'a3')!.group).toBe('group-1');
    expect(a.nodes.find((n) => n.id === 'a2')!.group).toBeUndefined();
    expect(a.groups).toEqual([{ id: 'group-1', name: 'Group 1' }]);
  });

  it('honors explicit id/name and rejects taken ids', () => {
    const next = groupNodesInSpec(fixture(), 'A', ['a1', 'a2'], {
      id: 'hero',
      name: 'Hero section',
    });
    expect(next.screens[0].groups).toEqual([{ id: 'hero', name: 'Hero section' }]);
    expect(() =>
      groupNodesInSpec(next, 'A', ['a3'], { id: 'hero' }),
    ).toThrow(/already exists/);
  });

  it('regrouping steals members and prunes the emptied group', () => {
    let s = groupNodesInSpec(fixture(), 'A', ['a1', 'a2']);
    s = groupNodesInSpec(s, 'A', ['a1', 'a2', 'a3']);
    const a = s.screens[0];
    // The fresh id is allocated before the emptied group-1 prunes away, so
    // exactly one group survives and every node belongs to it.
    expect(a.groups).toHaveLength(1);
    const id = a.groups![0].id;
    expect(a.nodes.every((n) => n.group === id)).toBe(true);
  });

  it('collects errors for off-screen nodes', () => {
    expect(() => groupNodesInSpec(fixture(), 'A', ['a1', 'b1'])).toThrow(
      /Node not on screen A: b1/,
    );
    expect(() => groupNodesInSpec(fixture(), 'Z', ['a1'])).toThrow(
      /Unknown screen id: Z/,
    );
  });

  it('keeps other screens identity-equal', () => {
    const before = fixture();
    const next = groupNodesInSpec(before, 'A', ['a1']);
    expect(next.screens[1]).toBe(before.screens[1]);
  });
});

// Two screens that BOTH own a 'group-1' — group ids are only unique per
// screen, so unscoped resolution first-matches A.
const collidingGroups = (): UISpec =>
  spec([
    {
      ...screen('A', [node('a1', { group: 'group-1' })]),
      groups: [{ id: 'group-1', name: 'A pair' }],
    },
    {
      ...screen('B', [node('b1', { group: 'group-1' }), node('b2')]),
      groups: [{ id: 'group-1', name: 'B pair' }],
    },
  ]);

describe('ungroupNodesInSpec', () => {
  it('strips tags, removes the registry entry, keeps z order', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1', 'a3']);
    const next = ungroupNodesInSpec(grouped, 'group-1');
    const a = next.screens[0];
    expect(a.nodes.map((n) => n.id)).toEqual(['a2', 'a1', 'a3']);
    expect(a.nodes.every((n) => n.group === undefined)).toBe(true);
    expect(a.groups).toBeUndefined();
  });

  it('errors on unknown group', () => {
    expect(() => ungroupNodesInSpec(fixture(), 'nope')).toThrow(/Unknown group/);
  });

  it('scopes resolution to screenId when group ids collide', () => {
    const input = collidingGroups();
    const next = ungroupNodesInSpec(input, 'group-1', 'B');
    expect(next.screens[1].groups).toBeUndefined();
    expect(next.screens[1].nodes[0].group).toBeUndefined();
    // A's distinct same-id group is untouched (identity).
    expect(next.screens[0]).toBe(input.screens[0]);
  });

  it('keeps first-match behavior when screenId is omitted', () => {
    const next = ungroupNodesInSpec(collidingGroups(), 'group-1');
    expect(next.screens[0].groups).toBeUndefined();
    expect(next.screens[1].groups).toEqual([
      { id: 'group-1', name: 'B pair' },
    ]);
  });

  it('throws when the scoped screen has no such group', () => {
    expect(() =>
      ungroupNodesInSpec(collidingGroups(), 'group-1', 'C'),
    ).toThrow(/Unknown group id on screen C: group-1/);
  });
});

describe('renameGroupInSpec', () => {
  it('renames and trims', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1'], { id: 'g' });
    const next = renameGroupInSpec(grouped, 'g', '  Header  ');
    expect(next.screens[0].groups).toEqual([{ id: 'g', name: 'Header' }]);
  });

  it('rejects empty names and unknown groups', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1'], { id: 'g' });
    expect(() => renameGroupInSpec(grouped, 'g', '   ')).toThrow(/empty/);
    expect(() => renameGroupInSpec(grouped, 'zz', 'x')).toThrow(/Unknown group/);
  });

  it('scopes resolution to screenId when group ids collide', () => {
    const next = renameGroupInSpec(collidingGroups(), 'group-1', 'Renamed', 'B');
    expect(next.screens[0].groups).toEqual([
      { id: 'group-1', name: 'A pair' },
    ]);
    expect(next.screens[1].groups).toEqual([
      { id: 'group-1', name: 'Renamed' },
    ]);
  });

  it('keeps first-match behavior when screenId is omitted', () => {
    const next = renameGroupInSpec(collidingGroups(), 'group-1', 'Renamed');
    expect(next.screens[0].groups).toEqual([
      { id: 'group-1', name: 'Renamed' },
    ]);
    expect(next.screens[1].groups).toEqual([
      { id: 'group-1', name: 'B pair' },
    ]);
  });

  it('throws when the scoped screen has no such group', () => {
    expect(() =>
      renameGroupInSpec(collidingGroups(), 'group-1', 'x', 'C'),
    ).toThrow(/Unknown group id on screen C: group-1/);
  });
});

describe('moveNodeInSpec', () => {
  it('moves to an explicit index, clamped', () => {
    const next = moveNodeInSpec(fixture(), 'a3', 0);
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['a3', 'a1', 'a2']);
    const clamped = moveNodeInSpec(fixture(), 'a1', 99);
    expect(clamped.screens[0].nodes.map((n) => n.id)).toEqual(['a2', 'a3', 'a1']);
  });

  it('joins a group with group: string and leaves with null', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1', 'a2'], { id: 'g' });
    const joined = moveNodeInSpec(grouped, 'a3', 1, 'g');
    expect(joined.screens[0].nodes.find((n) => n.id === 'a3')!.group).toBe('g');

    const left = moveNodeInSpec(joined, 'a1', 2, null);
    expect(left.screens[0].nodes.find((n) => n.id === 'a1')!.group).toBeUndefined();
  });

  it('prunes a group emptied by the last member leaving', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1'], { id: 'g' });
    const next = moveNodeInSpec(grouped, 'a1', 0, null);
    expect(next.screens[0].groups).toBeUndefined();
  });

  it('errors on unknown node or unknown target group', () => {
    expect(() => moveNodeInSpec(fixture(), 'zz', 0)).toThrow(/Unknown node/);
    expect(() => moveNodeInSpec(fixture(), 'a1', 0, 'g')).toThrow(/Unknown group/);
  });

  it('re-coalesces a group fractured by the landing index', () => {
    const a: UIScreen = {
      ...screen('A', [
        node('g1', { group: 'g' }),
        node('g2', { group: 'g' }),
        node('x'),
        node('y'),
      ]),
      groups: [{ id: 'g', name: 'Pair' }],
    };
    // Joining g at the very top would strand y between the block and the
    // moved node — the block re-coalesces anchored at its topmost member.
    const next = moveNodeInSpec(spec([a]), 'x', 3, 'g');
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['y', 'g1', 'g2', 'x']);
    expect(
      next.screens[0].nodes.filter((n) => n.group === 'g').map((n) => n.id),
    ).toEqual(['g1', 'g2', 'x']);
  });

  it('never fractures an uninvolved group: an interior landing index snaps to the block boundary', () => {
    const a: UIScreen = {
      ...screen('A', [
        node('g1', { group: 'g' }),
        node('g2', { group: 'g' }),
        node('x'),
      ]),
      groups: [{ id: 'g', name: 'Pair' }],
    };
    // Index 1 is interior to g's block — the ungrouped node snaps to the
    // boundary instead of splitting g1 from g2.
    const next = moveNodeInSpec(spec([a]), 'x', 1);
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['x', 'g1', 'g2']);
    expect(
      next.screens[0].nodes.filter((n) => n.group === 'g').map((n) => n.id),
    ).toEqual(['g1', 'g2']);
  });
});

describe('moveNodeInSpec across screens', () => {
  it('moves the node and inserts at the clamped target index', () => {
    const next = moveNodeInSpec(fixture(), 'a2', 1, undefined, 'B');
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a3']);
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['b1', 'a2']);
    const clamped = moveNodeInSpec(fixture(), 'a2', 99, undefined, 'B');
    expect(clamped.screens[1].nodes.map((n) => n.id)).toEqual(['b1', 'a2']);
    const bottom = moveNodeInSpec(fixture(), 'a2', -5, undefined, 'B');
    expect(bottom.screens[1].nodes.map((n) => n.id)).toEqual(['a2', 'b1']);
  });

  it('treats targetScreenId equal to the own screen as a same-screen move', () => {
    const next = moveNodeInSpec(fixture(), 'a3', 0, undefined, 'A');
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['a3', 'a1', 'a2']);
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['b1']);
  });

  it('strips the old screen group tag (undefined and null alike)', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1', 'a2'], { id: 'g' });
    const moved = moveNodeInSpec(grouped, 'a1', 0, undefined, 'B');
    expect(
      moved.screens[1].nodes.find((n) => n.id === 'a1')!.group,
    ).toBeUndefined();
    // a2 stays behind and keeps the group alive on the source screen.
    expect(moved.screens[0].nodes.find((n) => n.id === 'a2')!.group).toBe('g');
    const movedNull = moveNodeInSpec(grouped, 'a1', 0, null, 'B');
    expect(
      movedNull.screens[1].nodes.find((n) => n.id === 'a1')!.group,
    ).toBeUndefined();
  });

  it('prunes the source group when its last member leaves', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1'], { id: 'g' });
    const next = moveNodeInSpec(grouped, 'a1', 0, undefined, 'B');
    expect(next.screens[0].groups).toBeUndefined();
  });

  it('joins a group on the target screen', () => {
    const grouped = groupNodesInSpec(fixture(), 'B', ['b1'], { id: 'bg' });
    const next = moveNodeInSpec(grouped, 'a1', 1, 'bg', 'B');
    expect(next.screens[1].nodes.find((n) => n.id === 'a1')!.group).toBe('bg');
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['b1', 'a1']);
  });

  it('re-coalesces the target group when the landing index would fracture it', () => {
    const b: UIScreen = {
      ...screen('B', [
        node('b1', { group: 'bg' }),
        node('b2', { group: 'bg' }),
        node('b3'),
      ]),
      groups: [{ id: 'bg', name: 'Pair' }],
    };
    const next = moveNodeInSpec(
      spec([screen('A', [node('a1')]), b]),
      'a1',
      3,
      'bg',
      'B',
    );
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual([
      'b3',
      'b1',
      'b2',
      'a1',
    ]);
  });

  it('never fractures an uninvolved target group: an interior landing snaps to the boundary', () => {
    const b: UIScreen = {
      ...screen('B', [
        node('b1', { group: 'bg' }),
        node('b2', { group: 'bg' }),
      ]),
      groups: [{ id: 'bg', name: 'Pair' }],
    };
    // The ungrouped a1 lands at index 1 — interior to bg's block — and snaps
    // to the boundary instead of splitting b1 from b2.
    const next = moveNodeInSpec(
      spec([screen('A', [node('a1')]), b]),
      'a1',
      1,
      undefined,
      'B',
    );
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['a1', 'b1', 'b2']);
    expect(
      next.screens[1].nodes.find((n) => n.id === 'a1')!.group,
    ).toBeUndefined();
  });

  it('clamps coordinates into the target frame', () => {
    const input = spec([
      screen('A', [node('a1', { x: 700, y: 550 })]),
      { ...screen('B'), frame: { w: 200, h: 100 } },
    ]);
    const next = moveNodeInSpec(input, 'a1', 0, undefined, 'B');
    expect(next.screens[1].nodes[0]).toMatchObject({ x: 100, y: 60 });
  });

  it('clamps to 0 when the node is bigger than the frame', () => {
    const input = spec([
      screen('A', [node('a1', { x: 50, y: 30, width: 300, height: 200 })]),
      { ...screen('B'), frame: { w: 200, h: 100 } },
    ]);
    const next = moveNodeInSpec(input, 'a1', 0, undefined, 'B');
    expect(next.screens[1].nodes[0]).toMatchObject({ x: 0, y: 0 });
  });

  it('throws on an unknown target screen or unknown target group', () => {
    expect(() => moveNodeInSpec(fixture(), 'a1', 0, undefined, 'Z')).toThrow(
      /Unknown screen id: Z/,
    );
    expect(() => moveNodeInSpec(fixture(), 'a1', 0, 'g', 'B')).toThrow(
      /Unknown group id on screen B: g/,
    );
  });

  it('keeps untouched screens identity-equal', () => {
    const input = spec([
      screen('A', [node('a1'), node('a2')]),
      screen('B', [node('b1')]),
      screen('C', [node('c1')]),
    ]);
    const next = moveNodeInSpec(input, 'a1', 0, undefined, 'B');
    expect(next.screens[2]).toBe(input.screens[2]);
  });
});

describe('moveGroupInSpec', () => {
  const groupedFixture = (): UISpec =>
    spec([
      {
        ...screen('A', [
          node('a1'),
          node('g1', { group: 'g' }),
          node('g2', { group: 'g' }),
          node('a2'),
        ]),
        groups: [{ id: 'g', name: 'Pair' }],
      },
      screen('B', [node('b1')]),
    ]);

  it('reorders the block within its screen, members staying in order', () => {
    const toBottom = moveGroupInSpec(groupedFixture(), 'g', 0);
    expect(toBottom.screens[0].nodes.map((n) => n.id)).toEqual([
      'g1',
      'g2',
      'a1',
      'a2',
    ]);
    const toTop = moveGroupInSpec(groupedFixture(), 'g', 99);
    expect(toTop.screens[0].nodes.map((n) => n.id)).toEqual([
      'a1',
      'a2',
      'g1',
      'g2',
    ]);
  });

  it('reorders relative to another group block', () => {
    const input = spec([
      {
        ...screen('A', [
          node('p1', { group: 'p' }),
          node('p2', { group: 'p' }),
          node('q1', { group: 'q' }),
        ]),
        groups: [
          { id: 'p', name: 'P' },
          { id: 'q', name: 'Q' },
        ],
      },
    ]);
    const next = moveGroupInSpec(input, 'p', 1);
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['q1', 'p1', 'p2']);
  });

  it('moves the block to another screen with its registry entry', () => {
    const next = moveGroupInSpec(groupedFixture(), 'g', 1, 'B');
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual(['a1', 'a2']);
    expect(next.screens[0].groups).toBeUndefined();
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['b1', 'g1', 'g2']);
    expect(next.screens[1].groups).toEqual([{ id: 'g', name: 'Pair' }]);
    expect(
      next.screens[1].nodes.filter((n) => n.group === 'g').map((n) => n.id),
    ).toEqual(['g1', 'g2']);
  });

  it('mints a fresh id (keeping the name) on a target-side id collision', () => {
    const input = spec([
      {
        ...screen('A', [node('a1', { group: 'group-1' })]),
        groups: [{ id: 'group-1', name: 'Pair' }],
      },
      {
        ...screen('B', [node('b1', { group: 'group-1' })]),
        groups: [{ id: 'group-1', name: 'Other' }],
      },
    ]);
    const next = moveGroupInSpec(input, 'group-1', 1, 'B');
    expect(next.screens[1].groups).toEqual([
      { id: 'group-1', name: 'Other' },
      { id: 'group-2', name: 'Pair' },
    ]);
    expect(next.screens[1].nodes.find((n) => n.id === 'a1')!.group).toBe(
      'group-2',
    );
    expect(next.screens[1].nodes.find((n) => n.id === 'b1')!.group).toBe(
      'group-1',
    );
  });

  it('shifts all members by one common delta to fit the target frame', () => {
    const input = spec([
      {
        ...screen('A', [
          node('g1', { x: 600, y: 20, group: 'g' }),
          node('g2', { x: 700, y: 50, group: 'g' }),
        ]),
        groups: [{ id: 'g', name: 'Pair' }],
      },
      { ...screen('B'), frame: { w: 200, h: 100 } },
    ]);
    const next = moveGroupInSpec(input, 'g', 0, 'B');
    const [g1, g2] = next.screens[1].nodes;
    // Box origin (600, 20) clamps to (0, 20); internal 100px offset survives.
    expect(g1).toMatchObject({ x: 0, y: 20 });
    expect(g2).toMatchObject({ x: 100, y: 50 });
  });

  it('clamps the box origin to 0 when the box is bigger than the frame', () => {
    const input = spec([
      {
        ...screen('A', [node('g1', { x: 100, y: 200, width: 300, group: 'g' })]),
        groups: [{ id: 'g', name: 'Big' }],
      },
      { ...screen('B'), frame: { w: 200, h: 100 } },
    ]);
    const next = moveGroupInSpec(input, 'g', 0, 'B');
    expect(next.screens[1].nodes[0]).toMatchObject({ x: 0, y: 60 });
  });

  it('throws on unknown group or unknown target screen', () => {
    expect(() => moveGroupInSpec(fixture(), 'nope', 0)).toThrow(
      /Unknown group id: nope/,
    );
    expect(() => moveGroupInSpec(groupedFixture(), 'g', 0, 'Z')).toThrow(
      /Unknown screen id: Z/,
    );
  });

  it('resolves via sourceScreenId when group ids collide across screens', () => {
    const input = collidingGroups();
    // Unscoped, 'group-1' would first-match screen A — sourceScreenId pins
    // resolution to B's distinct same-id group.
    const next = moveGroupInSpec(input, 'group-1', 99, undefined, 'B');
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual(['b2', 'b1']);
    expect(next.screens[0]).toBe(input.screens[0]);
  });

  it('throws when sourceScreenId has no such group', () => {
    const input = spec([
      {
        ...screen('A', [node('a1', { group: 'group-1' })]),
        groups: [{ id: 'group-1', name: 'Pair' }],
      },
      screen('B', [node('b1')]),
    ]);
    expect(() =>
      moveGroupInSpec(input, 'group-1', 0, undefined, 'B'),
    ).toThrow(/Unknown group id on screen B: group-1/);
  });

  it('throws on a ghost registry entry with zero members', () => {
    const input = spec([
      {
        ...screen('A', [node('a1')]),
        groups: [{ id: 'ghost', name: 'Ghost' }],
      },
      screen('B', [node('b1')]),
    ]);
    // Same-screen and cross-screen alike — the cross-screen path must not
    // silently delete the entry from both screens.
    expect(() => moveGroupInSpec(input, 'ghost', 0)).toThrow(
      /Group has no members: ghost/,
    );
    expect(() => moveGroupInSpec(input, 'ghost', 0, 'B')).toThrow(
      /Group has no members: ghost/,
    );
    expect(input.screens[0].groups).toEqual([{ id: 'ghost', name: 'Ghost' }]);
  });

  it('never fractures another block on a same-screen interior landing', () => {
    const input = spec([
      {
        ...screen('A', [
          node('p1', { group: 'p' }),
          node('p2', { group: 'p' }),
          node('q1', { group: 'q' }),
          node('q2', { group: 'q' }),
        ]),
        groups: [
          { id: 'p', name: 'P' },
          { id: 'q', name: 'Q' },
        ],
      },
    ]);
    // Index 1 is interior to p's block — q snaps below it instead of
    // splitting p1 from p2; both blocks stay contiguous.
    const next = moveGroupInSpec(input, 'q', 1);
    expect(next.screens[0].nodes.map((n) => n.id)).toEqual([
      'q1',
      'q2',
      'p1',
      'p2',
    ]);
  });

  it('never fractures a target block on a cross-screen interior landing', () => {
    const input = spec([
      {
        ...screen('A', [
          node('g1', { group: 'g' }),
          node('g2', { group: 'g' }),
        ]),
        groups: [{ id: 'g', name: 'Pair' }],
      },
      {
        ...screen('B', [
          node('p1', { group: 'p' }),
          node('p2', { group: 'p' }),
          node('b3'),
        ]),
        groups: [{ id: 'p', name: 'P' }],
      },
    ]);
    // Landing index 1 is interior to p's block on B — the moved block stays
    // contiguous and p re-coalesces above it.
    const next = moveGroupInSpec(input, 'g', 1, 'B');
    expect(next.screens[1].nodes.map((n) => n.id)).toEqual([
      'g1',
      'g2',
      'p1',
      'p2',
      'b3',
    ]);
    expect(
      next.screens[1].nodes.filter((n) => n.group === 'p').map((n) => n.id),
    ).toEqual(['p1', 'p2']);
    expect(
      next.screens[1].nodes.filter((n) => n.group === 'g').map((n) => n.id),
    ).toEqual(['g1', 'g2']);
  });

  it('keeps untouched screens identity-equal', () => {
    const input = spec([
      groupedFixture().screens[0],
      screen('B', [node('b1')]),
      screen('C', [node('c1')]),
    ]);
    const next = moveGroupInSpec(input, 'g', 0, 'B');
    expect(next.screens[2]).toBe(input.screens[2]);
    const same = moveGroupInSpec(input, 'g', 0);
    expect(same.screens[1]).toBe(input.screens[1]);
    expect(same.screens[2]).toBe(input.screens[2]);
  });
});

describe('normalizeScreenGroups', () => {
  it('returns the same reference when the screen is already clean', () => {
    const clean: UIScreen = {
      ...screen('A', [
        node('a1'),
        node('g1', { group: 'g' }),
        node('g2', { group: 'g' }),
      ]),
      groups: [{ id: 'g', name: 'Pair' }],
    };
    expect(normalizeScreenGroups(clean)).toBe(clean);
    const ungrouped = screen('A', [node('a1')]);
    expect(normalizeScreenGroups(ungrouped)).toBe(ungrouped);
  });

  it('re-coalesces fractured members anchored at the topmost member', () => {
    const fractured: UIScreen = {
      ...screen('A', [
        node('g1', { group: 'g' }),
        node('x'),
        node('g2', { group: 'g' }),
        node('y'),
      ]),
      groups: [{ id: 'g', name: 'Pair' }],
    };
    const next = normalizeScreenGroups(fractured);
    // Block lands where g2 (topmost member) sat among the non-members.
    expect(next.nodes.map((n) => n.id)).toEqual(['x', 'g1', 'g2', 'y']);
  });

  it('strips orphan tags and prunes empty registry entries', () => {
    const dirty: UIScreen = {
      ...screen('A', [node('a1', { group: 'ghost' }), node('a2')]),
      groups: [{ id: 'empty', name: 'Empty' }],
    };
    const next = normalizeScreenGroups(dirty);
    expect(next.nodes.find((n) => n.id === 'a1')!.group).toBeUndefined();
    expect(next.groups).toBeUndefined();
  });

  it('repairs multiple groups in registry order', () => {
    const fractured: UIScreen = {
      ...screen('A', [
        node('p1', { group: 'p' }),
        node('q1', { group: 'q' }),
        node('p2', { group: 'p' }),
        node('q2', { group: 'q' }),
      ]),
      groups: [
        { id: 'p', name: 'P' },
        { id: 'q', name: 'Q' },
      ],
    };
    const next = normalizeScreenGroups(fractured);
    expect(next.nodes.map((n) => n.id)).toEqual(['p1', 'p2', 'q1', 'q2']);
  });
});

describe('groups across other ops', () => {
  it('removeNodesFromSpec prunes groups that lost all members', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1', 'a3'], { id: 'g' });
    const next = removeNodesFromSpec(grouped, ['a1', 'a3']);
    expect(next.screens[0].groups).toBeUndefined();
  });

  it('duplicateScreenInSpec carries groups and member tags', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1', 'a2'], {
      id: 'g',
      name: 'Pair',
    });
    const next = duplicateScreenInSpec(grouped, 'A', 'A2');
    const dup = next.screens[2];
    expect(dup.groups).toEqual([{ id: 'g', name: 'Pair' }]);
    expect(dup.nodes.find((n) => n.id === 'A2-a1')!.group).toBe('g');
  });

  it('describeLayers surfaces groups and member tags', () => {
    const grouped = groupNodesInSpec(fixture(), 'A', ['a1'], {
      id: 'g',
      name: 'Solo',
    });
    const out = describeLayers(grouped, 'A');
    expect(out.screens[0].groups).toEqual([{ id: 'g', name: 'Solo' }]);
    expect(out.screens[0].layers.find((l) => l.id === 'a1')!.group).toBe('g');
    expect('group' in out.screens[0].layers.find((l) => l.id === 'a2')!).toBe(false);
  });
});

describe('findNodeInSpec', () => {
  it('finds across screens and returns null when absent', () => {
    expect(findNodeInSpec(fixture(), 'b1')!.id).toBe('b1');
    expect(findNodeInSpec(fixture(), 'zz')).toBeNull();
  });
});

describe('sourceHash provenance', () => {
  it('duplicateScreenInSpec drops sourceHash along with sourceFile', () => {
    const withProvenance = spec([
      {
        ...screen('A', [node('a1')]),
        sourceFile: 'MyApp/A.swift',
        sourceHash: 'abc123',
      },
    ]);
    const out = duplicateScreenInSpec(withProvenance, 'A', 'A2');
    expect('sourceFile' in out.screens[1]).toBe(false);
    expect('sourceHash' in out.screens[1]).toBe(false);
  });
});

// ── design library ──────────────────────────────────────────────────────────

const component = (
  id: string,
  overrides: Partial<UIComponent> = {},
): UIComponent => ({
  id,
  name: `Component ${id}`,
  frame: { w: 200, h: 60 },
  nodes: [node('icon', { width: 24, height: 24 }), node('label', { x: 32, width: 120 })],
  ...overrides,
});

describe('carryLibraryForward', () => {
  const library = {
    designSystem: { colors: [{ name: 'Brand', value: '#6159E1' }] },
    components: [component('task-row')],
  };

  it('carries omitted designSystem/components from prev', () => {
    const prev: UISpec = { screens: [], ...library };
    const next: UISpec = { screens: [screen('A')] };
    const out = carryLibraryForward(prev, next);
    expect(out.designSystem).toBe(library.designSystem);
    expect(out.components).toBe(library.components);
    expect(out.screens).toBe(next.screens);
  });

  it('respects explicit values, including empty ones', () => {
    const prev: UISpec = { screens: [], ...library };
    const next: UISpec = { screens: [], designSystem: {}, components: [] };
    const out = carryLibraryForward(prev, next);
    expect(out).toBe(next); // nothing to carry — identity preserved
    expect(out.designSystem).toEqual({});
    expect(out.components).toEqual([]);
  });

  it('returns next untouched when prev has no library', () => {
    const next: UISpec = { screens: [] };
    expect(carryLibraryForward({ screens: [] }, next)).toBe(next);
  });
});

describe('adoptSnapshotSpec', () => {
  const freshLibrary = {
    designSystem: { colors: [{ name: 'Brand', value: '#6159E1' }] },
    components: [component('task-row')],
  };
  const staleLibrary = {
    designSystem: { colors: [{ name: 'OldBrand', value: '#000000' }] },
    components: [component('old-row')],
  };

  it('takes screens from the snapshot and the library from the cache', () => {
    const cache: UISpec = { screens: [], ...freshLibrary };
    const snapshot: UISpec = { screens: [screen('A')], ...staleLibrary };
    const out = adoptSnapshotSpec(cache, snapshot);
    expect(out.screens).toBe(snapshot.screens);
    // A stale tab's included library must NOT revert the cache's fresh one.
    expect(out.designSystem).toBe(freshLibrary.designSystem);
    expect(out.components).toBe(freshLibrary.components);
  });

  it('keeps an explicitly cleared cache library over a snapshot copy', () => {
    const cache: UISpec = { screens: [], designSystem: {}, components: [] };
    const out = adoptSnapshotSpec(cache, {
      screens: [],
      ...staleLibrary,
    });
    expect(out.designSystem).toEqual({});
    expect(out.components).toEqual([]);
  });

  it('fills a library-less cache from the snapshot (localStorage restore)', () => {
    const out = adoptSnapshotSpec(
      { screens: [] },
      { screens: [screen('A')], ...freshLibrary },
    );
    expect(out.designSystem).toBe(freshLibrary.designSystem);
    expect(out.components).toBe(freshLibrary.components);
  });

  it('omits library fields when neither side has them', () => {
    const out = adoptSnapshotSpec({ screens: [] }, { screens: [screen('A')] });
    expect(out).toEqual({ screens: [screen('A')] });
    expect('designSystem' in out).toBe(false);
    expect('components' in out).toBe(false);
  });
});

describe('applyComponentToSpec', () => {
  it('appends a new component and replaces by id', () => {
    const withOne = applyComponentToSpec({ screens: [] }, component('task-row'));
    expect(withOne.components?.map((c) => c.id)).toEqual(['task-row']);
    const replaced = applyComponentToSpec(
      withOne,
      component('task-row', { name: 'Renamed' }),
    );
    expect(replaced.components).toHaveLength(1);
    expect(replaced.components?.[0].name).toBe('Renamed');
  });

  it('rejects duplicate node ids within the template', () => {
    expect(() =>
      applyComponentToSpec(
        { screens: [] },
        component('x', { nodes: [node('a'), node('a')] }),
      ),
    ).toThrow(/Duplicate node id within component template/);
  });

  it('carries the prior sourceFile when a replacement omits it', () => {
    const withOne = applyComponentToSpec(
      { screens: [] },
      component('task-row', { sourceFile: 'App/TaskRow.swift' }),
    );
    const replaced = applyComponentToSpec(
      withOne,
      component('task-row', { name: 'Renamed' }),
    );
    expect(replaced.components?.[0].sourceFile).toBe('App/TaskRow.swift');
    const restated = applyComponentToSpec(
      replaced,
      component('task-row', { sourceFile: 'App/Other.swift' }),
    );
    expect(restated.components?.[0].sourceFile).toBe('App/Other.swift');
  });
});

describe('validateComponentList', () => {
  it('collects duplicate component ids and intra-template node dupes', () => {
    const errors = validateComponentList([
      component('a'),
      component('a'),
      component('b', { nodes: [node('x'), node('x')] }),
    ]);
    expect(errors).toEqual([
      'Duplicate component id: a',
      'Duplicate node id within component template "b": x',
    ]);
  });

  it('passes a clean list', () => {
    expect(validateComponentList([component('a'), component('b')])).toEqual([]);
  });
});

describe('instantiateComponentInSpec', () => {
  const base = (): UISpec => ({
    screens: [screen('A', [node('a1')])],
    components: [component('task-row')],
  });

  it('stamps offset nodes with fresh ids in a named group', () => {
    const input = base();
    const { spec: out, nodeIds, groupId } = instantiateComponentInSpec(
      input,
      'task-row',
      'A',
      { x: 50, y: 100 },
    );
    expect(nodeIds).toEqual(['task-row-1-icon', 'task-row-1-label']);
    const inserted = out.screens[0].nodes.slice(1);
    expect(inserted.map((n) => n.id)).toEqual(nodeIds);
    expect(inserted[0]).toMatchObject({ x: 50, y: 100, group: groupId });
    expect(inserted[1]).toMatchObject({ x: 82, y: 100, group: groupId });
    expect(out.screens[0].groups).toEqual([
      { id: groupId, name: 'Component task-row' },
    ]);
    // template untouched
    expect(out.components).toBe(input.components);
  });

  it('bumps the instance counter to avoid id collisions', () => {
    const first = instantiateComponentInSpec(base(), 'task-row', 'A');
    const second = instantiateComponentInSpec(first.spec, 'task-row', 'A');
    expect(second.nodeIds).toEqual(['task-row-2-icon', 'task-row-2-label']);
  });

  it('clamps the origin inside the frame', () => {
    const { spec: out } = instantiateComponentInSpec(base(), 'task-row', 'A', {
      x: 5000,
      y: -10,
    });
    const inserted = out.screens[0].nodes.slice(1);
    expect(inserted[0].x).toBe(600); // 800 - 200
    expect(inserted[0].y).toBe(0);
  });

  it('errors on unknown component or screen', () => {
    expect(() => instantiateComponentInSpec(base(), 'nope', 'A')).toThrow(
      /Unknown component id: nope/,
    );
    expect(() => instantiateComponentInSpec(base(), 'task-row', 'Z')).toThrow(
      /Unknown screen id: Z/,
    );
  });

  it('refuses to stamp a template carrying duplicate node ids', () => {
    // Such a template can only arrive via paths that skip the validated
    // writes (hand-edited design.json, raw snapshot) — instantiation is the
    // last line of defense for the global node-id invariant.
    const poisoned: UISpec = {
      screens: [screen('A')],
      components: [
        component('task-row', { nodes: [node('a'), node('a')] }),
      ],
    };
    expect(() =>
      instantiateComponentInSpec(poisoned, 'task-row', 'A'),
    ).toThrow(/Duplicate node id within component template/);
  });

  it('preserves identity of untouched screens', () => {
    const input: UISpec = {
      screens: [screen('A'), screen('B')],
      components: [component('task-row')],
    };
    const { spec: out } = instantiateComponentInSpec(input, 'task-row', 'A');
    expect(out.screens[1]).toBe(input.screens[1]);
  });
});

describe('describeDesignLibrary', () => {
  it('summarizes components without node arrays', () => {
    const out = describeDesignLibrary({
      screens: [],
      designSystem: { spacing: [16] },
      components: [
        component('task-row', { usedBy: ['home'], sourceFile: 'A/Row.swift' }),
      ],
    });
    expect(out.designSystem).toEqual({ spacing: [16] });
    expect(out.components).toEqual([
      {
        id: 'task-row',
        name: 'Component task-row',
        frame: { w: 200, h: 60 },
        nodeCount: 2,
        usedBy: ['home'],
        sourceFile: 'A/Row.swift',
      },
    ]);
  });

  it('omits absent fields', () => {
    const out = describeDesignLibrary({ screens: [] });
    expect(out).toEqual({ components: [] });
  });
});
