import { describe, it, expect } from 'vitest';
import { sanitizeAppState } from './canvasBus';

describe('sanitizeAppState', () => {
  it('passes null through unchanged', () => {
    expect(sanitizeAppState(null)).toBeNull();
  });

  it('passes undefined through unchanged', () => {
    expect(sanitizeAppState(undefined)).toBeUndefined();
  });

  it('strips collaborators / pointers / followedBy regardless of value type', () => {
    const input = {
      collaborators: new Map([['a', { id: 'a' }]]),
      pointers: { x: 1 },
      followedBy: new Set(['x']),
      zoom: 1,
    };
    const out = sanitizeAppState(input);
    expect(out).toEqual({ zoom: 1 });
  });

  it('strips stale layout keys (width, height, offsetLeft, offsetTop)', () => {
    const out = sanitizeAppState({
      width: 800,
      height: 600,
      offsetLeft: 10,
      offsetTop: 20,
      viewBackgroundColor: '#fff',
    });
    expect(out).toEqual({ viewBackgroundColor: '#fff' });
  });

  it('strips Map and Set values at any key', () => {
    const out = sanitizeAppState({
      arbitrary: new Map(),
      somethingElse: new Set(),
      keep: 'me',
    });
    expect(out).toEqual({ keep: 'me' });
  });

  it('preserves nested objects without recursing', () => {
    // The function does NOT recurse — Map/Set inside a nested object survive.
    // Lock down current shallow-only behavior so an accidental recursion doesn't
    // change the contract.
    const nested = { inner: new Map([['a', 1]]) };
    const out = sanitizeAppState({ outer: nested, scalar: 42 });
    expect(out).toEqual({ outer: nested, scalar: 42 });
    expect((out as { outer: { inner: Map<string, number> } }).outer.inner).toBeInstanceOf(Map);
  });

  it('preserves arrays as-is', () => {
    const out = sanitizeAppState({ items: [1, 2, 3] });
    expect(out).toEqual({ items: [1, 2, 3] });
  });

  it('returns a fresh object (does not mutate input)', () => {
    const input = { collaborators: new Map(), keep: 1 };
    const out = sanitizeAppState(input);
    expect(out).not.toBe(input);
    expect('collaborators' in input).toBe(true);
  });
});
