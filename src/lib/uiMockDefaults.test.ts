import { describe, expect, it } from 'vitest';
import {
  NODE_DEFAULTS,
  NODE_LABELS,
  NODE_TYPE_ORDER,
  makeNode,
} from './uiMockDefaults';
import type { UINodeType } from './uiMockProtocol';

const ALL_TYPES: UINodeType[] = [
  'div',
  'text',
  'heading',
  'Button',
  'Input',
  'Textarea',
  'Badge',
  'Separator',
  'Image',
  'Icon',
];

describe('uiMockDefaults tables', () => {
  it('covers every node type with a default, label, and palette slot', () => {
    for (const type of ALL_TYPES) {
      expect(NODE_DEFAULTS[type]).toBeDefined();
      expect(NODE_LABELS[type]).toBeTruthy();
    }
    expect([...NODE_TYPE_ORDER].sort()).toEqual([...ALL_TYPES].sort());
  });
});

describe('makeNode', () => {
  it('produces a valid node with default geometry and rounded coords', () => {
    const n = makeNode('Button', 12.6, 30.2);
    expect(n.type).toBe('Button');
    expect(n.x).toBe(13);
    expect(n.y).toBe(30);
    expect(n.width).toBe(NODE_DEFAULTS.Button.width);
    expect(n.height).toBe(NODE_DEFAULTS.Button.height);
    expect(n.text).toBe('Button');
    expect(n.props).toEqual({ variant: 'default' });
    expect(n.id).toMatch(/^node-/);
  });

  it('omits text/props/className when the type has no default', () => {
    const n = makeNode('div', 0, 0);
    expect(n.text).toBeUndefined();
    expect(n.props).toBeUndefined();
  });

  it('generates unique ids', () => {
    const ids = new Set(
      Array.from({ length: 50 }, () => makeNode('text', 0, 0).id),
    );
    expect(ids.size).toBe(50);
  });
});
