// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { recentProjects } from './recentProjects';

const KEY = 'tango.workspace.recent';

beforeEach(() => {
  window.localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('recentProjects.list', () => {
  it('returns [] when localStorage is empty', () => {
    expect(recentProjects.list()).toEqual([]);
  });

  it('returns [] when stored value is malformed JSON', () => {
    window.localStorage.setItem(KEY, '{ not json');
    expect(recentProjects.list()).toEqual([]);
  });

  it('returns [] when stored value is not an array', () => {
    window.localStorage.setItem(KEY, JSON.stringify({ a: 1 }));
    expect(recentProjects.list()).toEqual([]);
  });

  it('filters entries missing path or name', () => {
    window.localStorage.setItem(
      KEY,
      JSON.stringify([
        { path: '/a', name: 'A' },
        { path: '/b' }, // missing name
        { name: 'C' }, // missing path
        null,
        { path: '/d', name: 'D' },
      ]),
    );
    expect(recentProjects.list()).toEqual([
      { path: '/a', name: 'A' },
      { path: '/d', name: 'D' },
    ]);
  });
});

describe('recentProjects.add', () => {
  it('adds a new entry to an empty list', () => {
    const out = recentProjects.add({ path: '/x', name: 'X' });
    expect(out).toEqual([{ path: '/x', name: 'X' }]);
    expect(recentProjects.list()).toEqual(out);
  });

  it('moves an existing path to the head (MRU)', () => {
    recentProjects.add({ path: '/a', name: 'A' });
    recentProjects.add({ path: '/b', name: 'B' });
    recentProjects.add({ path: '/c', name: 'C' });
    const out = recentProjects.add({ path: '/a', name: 'A' });
    expect(out).toEqual([
      { path: '/a', name: 'A' },
      { path: '/c', name: 'C' },
      { path: '/b', name: 'B' },
    ]);
  });

  it('caps the list at MAX = 8', () => {
    for (let i = 0; i < 10; i++) {
      recentProjects.add({ path: `/p${i}`, name: `P${i}` });
    }
    const list = recentProjects.list();
    expect(list).toHaveLength(8);
    // Newest at head, oldest evicted.
    expect(list[0]).toEqual({ path: '/p9', name: 'P9' });
    expect(list[7]).toEqual({ path: '/p2', name: 'P2' });
  });

  it('swallows quota errors from setItem without throwing', () => {
    vi.spyOn(window.localStorage, 'setItem').mockImplementation(() => {
      throw new Error('quota exceeded');
    });
    expect(() => recentProjects.add({ path: '/x', name: 'X' })).not.toThrow();
  });
});

describe('recentProjects.remove', () => {
  it('removes a matching path', () => {
    recentProjects.add({ path: '/a', name: 'A' });
    recentProjects.add({ path: '/b', name: 'B' });
    const out = recentProjects.remove('/a');
    expect(out).toEqual([{ path: '/b', name: 'B' }]);
  });

  it('is a no-op for a non-existent path', () => {
    recentProjects.add({ path: '/a', name: 'A' });
    const out = recentProjects.remove('/missing');
    expect(out).toEqual([{ path: '/a', name: 'A' }]);
  });
});
