import { describe, expect, it } from 'vitest';
import {
  addNodesToScreen,
  appendScreenToSpec,
  describeLayers,
  duplicateScreenInSpec,
  removeNodesFromSpec,
  removeScreenFromSpec,
  reorderNodeInSpec,
  updateNodeInSpec,
  updateNodesInSpec,
  updateScreenInSpec,
} from './uiMockOps';
import type { UINode, UIScreen, UISpec } from './uiMockProtocol';

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
