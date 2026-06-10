import { describe, expect, it } from 'vitest';
import {
  computeSyncStatuses,
  hashSource,
  provenanceSignature,
} from './sourceHash';
import type { UIScreen, UISpec } from '@/lib/uiMockProtocol';

const screen = (id: string, over: Partial<UIScreen> = {}): UIScreen => ({
  id,
  title: id,
  frame: { w: 390, h: 844 },
  nodes: [],
  ...over,
});

describe('hashSource', () => {
  it('is stable and content-sensitive', () => {
    expect(hashSource('struct A {}')).toBe(hashSource('struct A {}'));
    expect(hashSource('struct A {}')).not.toBe(hashSource('struct B {}'));
    expect(hashSource('x')).toHaveLength(16);
  });
});

describe('computeSyncStatuses', () => {
  const reader =
    (files: Record<string, string | null>) =>
    async (rel: string): Promise<string | null> =>
      files[rel] ?? null;

  it('reports synced when the live hash matches', async () => {
    const content = 'struct LoginView {}';
    const spec: UISpec = {
      screens: [
        screen('login', {
          sourceFile: 'App/LoginView.swift',
          sourceHash: hashSource(content),
        }),
      ],
    };
    const out = await computeSyncStatuses(
      spec,
      reader({ 'App/LoginView.swift': content }),
    );
    expect(out).toEqual({ login: 'synced' });
  });

  it('reports stale when the file content changed', async () => {
    const spec: UISpec = {
      screens: [
        screen('login', {
          sourceFile: 'App/LoginView.swift',
          sourceHash: hashSource('old content'),
        }),
      ],
    };
    const out = await computeSyncStatuses(
      spec,
      reader({ 'App/LoginView.swift': 'new content' }),
    );
    expect(out).toEqual({ login: 'stale' });
  });

  it('reports missing when the file is unreadable', async () => {
    const spec: UISpec = {
      screens: [
        screen('login', { sourceFile: 'App/Gone.swift', sourceHash: 'h' }),
      ],
    };
    expect(await computeSyncStatuses(spec, reader({}))).toEqual({
      login: 'missing',
    });
  });

  it('legacy screens without a hash report synced (staleness unknowable)', async () => {
    const spec: UISpec = {
      screens: [screen('login', { sourceFile: 'App/LoginView.swift' })],
    };
    const out = await computeSyncStatuses(
      spec,
      reader({ 'App/LoginView.swift': 'anything' }),
    );
    expect(out).toEqual({ login: 'synced' });
  });

  it('skips unlinked screens and hashes shared files once', async () => {
    let reads = 0;
    const content = 'shared';
    const spec: UISpec = {
      screens: [
        screen('a', { sourceFile: 'App/S.swift', sourceHash: hashSource(content) }),
        screen('b', { sourceFile: 'App/S.swift', sourceHash: 'different' }),
        screen('c'),
      ],
    };
    const out = await computeSyncStatuses(spec, async () => {
      reads += 1;
      return content;
    });
    expect(out).toEqual({ a: 'synced', b: 'stale' });
    expect('c' in out).toBe(false);
    expect(reads).toBe(1);
  });
});

describe('provenanceSignature', () => {
  it('changes only when provenance fields change', () => {
    const a: UISpec = {
      screens: [screen('s', { sourceFile: 'f', sourceHash: 'h' })],
    };
    const geometryEdit: UISpec = {
      screens: [
        {
          ...a.screens[0],
          nodes: [
            { id: 'n', type: 'div', x: 1, y: 2, width: 3, height: 4 },
          ],
        },
      ],
    };
    expect(provenanceSignature(a)).toBe(provenanceSignature(geometryEdit));
    const hashChange: UISpec = {
      screens: [screen('s', { sourceFile: 'f', sourceHash: 'h2' })],
    };
    expect(provenanceSignature(a)).not.toBe(provenanceSignature(hashChange));
  });
});
