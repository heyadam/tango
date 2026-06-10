import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  _resetForTests,
  _writesSettled,
  designJsonPath,
  flushPendingPersist,
  loadSpecFromDisk,
  migrateEnvelope,
  parseSpecFile,
  schedulePersist,
  serializeSpecFile,
} from './uiMockPersist';
import type { UISpec } from '@/lib/uiMockProtocol';

const SAVED_AT = '2026-06-09T00:00:00.000Z';

const SPEC: UISpec = {
  screens: [
    {
      id: 'login',
      title: 'Login',
      frame: { w: 390, h: 844 },
      nodes: [
        {
          id: 'cta',
          type: 'Button',
          x: 24,
          y: 700,
          width: 342,
          height: 44,
          text: 'Sign in',
        },
      ],
    },
  ],
};

describe('serializeSpecFile / parseSpecFile', () => {
  it('round-trips a spec', () => {
    expect(parseSpecFile(serializeSpecFile(SPEC, SAVED_AT))).toEqual(SPEC);
  });

  it('round-trips a screen sourceFile intact', () => {
    const withSource: UISpec = {
      screens: [{ ...SPEC.screens[0], sourceFile: 'MyApp/LoginView.swift' }],
    };
    const loaded = parseSpecFile(serializeSpecFile(withSource, SAVED_AT));
    expect(loaded).toEqual(withSource);
    expect(loaded?.screens[0].sourceFile).toBe('MyApp/LoginView.swift');
  });

  it('emits a versioned envelope with trailing newline', () => {
    const raw = serializeSpecFile(SPEC, SAVED_AT);
    expect(raw.endsWith('\n')).toBe(true);
    const envelope = JSON.parse(raw);
    expect(envelope.version).toBe(1);
    expect(envelope.savedAt).toBe(SAVED_AT);
  });

  it('is stable: same spec → byte-identical output', () => {
    expect(serializeSpecFile(SPEC, SAVED_AT)).toBe(
      serializeSpecFile(SPEC, SAVED_AT),
    );
  });

  it('returns null for malformed JSON', () => {
    expect(parseSpecFile('not json {')).toBeNull();
  });

  it('returns null for a non-object root', () => {
    expect(parseSpecFile('[1,2]')).toBeNull();
    expect(parseSpecFile('42')).toBeNull();
  });

  it('returns null for an unknown (newer) version — never migrates down', () => {
    const raw = JSON.stringify({ version: 99, savedAt: SAVED_AT, spec: SPEC });
    expect(parseSpecFile(raw)).toBeNull();
  });

  it('returns null for a non-numeric version', () => {
    const raw = JSON.stringify({ version: '1', savedAt: SAVED_AT, spec: SPEC });
    expect(parseSpecFile(raw)).toBeNull();
  });

  it('returns null for a schema-invalid spec', () => {
    const bad = {
      version: 1,
      savedAt: SAVED_AT,
      spec: { screens: [{ id: 'x' }] },
    };
    expect(parseSpecFile(JSON.stringify(bad))).toBeNull();
  });
});

describe('migrateEnvelope', () => {
  it('passes a current-version envelope through untouched', () => {
    const envelope = { version: 1, spec: SPEC };
    expect(migrateEnvelope(envelope)).toEqual(envelope);
  });

  it('returns null when no migration path exists', () => {
    expect(migrateEnvelope({ version: 0, spec: {} })).toBeNull();
    expect(migrateEnvelope({ version: 99, spec: {} })).toBeNull();
  });
});

describe('write-behind persistence', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-persist-'));
    vi.useFakeTimers();
  });

  afterEach(async () => {
    _resetForTests();
    vi.useRealTimers();
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('writes the captured spec after the debounce window', async () => {
    schedulePersist(dir, SPEC);
    vi.advanceTimersByTime(800);
    await _writesSettled();
    const loaded = await loadSpecFromDisk(dir);
    expect(loaded).toEqual(SPEC);
  });

  it('trailing-edge debounce: only the last scheduled spec lands', async () => {
    const earlier: UISpec = { screens: [] };
    schedulePersist(dir, earlier);
    vi.advanceTimersByTime(300);
    schedulePersist(dir, SPEC);
    vi.advanceTimersByTime(800);
    await _writesSettled();
    expect(await loadSpecFromDisk(dir)).toEqual(SPEC);
  });

  it('capture semantics: pending writes for two workspaces both land in their own files', async () => {
    const dir2 = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-persist-'));
    try {
      const spec2: UISpec = { screens: [] };
      schedulePersist(dir, SPEC);
      schedulePersist(dir2, spec2);
      vi.advanceTimersByTime(800);
      await _writesSettled();
      expect(await loadSpecFromDisk(dir)).toEqual(SPEC);
      const raw2 = await fs.readFile(designJsonPath(dir2), 'utf8');
      expect(parseSpecFile(raw2)).toEqual(spec2);
    } finally {
      await fs.rm(dir2, { recursive: true, force: true });
    }
  });

  it('flushPendingPersist fires pending writes without waiting out the debounce', async () => {
    schedulePersist(dir, SPEC);
    flushPendingPersist();
    await _writesSettled();
    expect(await loadSpecFromDisk(dir)).toEqual(SPEC);
  });
});

describe('loadSpecFromDisk', () => {
  let dir: string;

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tango-persist-'));
  });

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('returns null when no file exists', async () => {
    expect(await loadSpecFromDisk(dir)).toBeNull();
  });

  it('rescues an invalid file aside instead of deleting it', async () => {
    const p = designJsonPath(dir);
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, 'corrupted garbage');
    expect(await loadSpecFromDisk(dir)).toBeNull();
    const entries = await fs.readdir(path.dirname(p));
    expect(entries.some((e) => e.startsWith('design.invalid-'))).toBe(true);
    expect(entries.includes('design.json')).toBe(false);
  });
});
