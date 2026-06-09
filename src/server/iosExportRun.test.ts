// State-machine tests for runExportAndRun with fully injected deps — no
// xcodebuild, no filesystem. The workspace/iOS-project slots live on
// globalThis, so we poke them via the internal setters.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  getExportRunState,
  runExportAndRun,
} from './iosExport';
import {
  _setIosProjectInternal,
  _setWorkspaceInternal,
} from './workspace';
import type { UISpec } from '@/lib/uiMockProtocol';
import type { IosProject } from './iosBuild';

const SPEC: UISpec = {
  screens: [
    {
      id: 's1',
      title: 'S1',
      frame: { w: 100, h: 100 },
      nodes: [
        { id: 'n1', type: 'text', x: 0, y: 0, width: 10, height: 10, text: 'x' },
      ],
    },
  ],
};

const PROJECT: IosProject = {
  projectPath: '/repo/MyApp.xcodeproj',
  projectKind: 'project',
  scheme: 'MyApp',
  bundleId: 'com.example.app',
  configurations: ['Debug', 'Release'],
};

function deps(overrides: Partial<Parameters<typeof runExportAndRun>[1]> = {}) {
  return {
    getSpec: () => SPEC,
    buildRun: vi.fn(async () => ({
      ok: true as const,
      bundleId: 'com.example.app',
      pid: 123,
      appPath: '/dd/MyApp.app',
      durationMs: 1000,
    })),
    resolveUdid: vi.fn(async () => 'UDID-1'),
    resolveDir: vi.fn(async () => ({
      dir: '/repo/MyApp/TangoGenerated',
      inclusion: 'fs-synced' as const,
    })),
    writeFiles: vi.fn(async () => {}),
    ...overrides,
  };
}

describe('runExportAndRun', () => {
  beforeEach(() => {
    _setWorkspaceInternal('/repo', 'persisted');
    _setIosProjectInternal({ kind: 'detected', project: PROJECT });
  });

  afterEach(() => {
    _setWorkspaceInternal(null, 'unset');
    _setIosProjectInternal({ kind: 'none' });
    // Drain any active state so tests don't leak into each other.
  });

  it('runs the full pipeline to done', async () => {
    const d = deps();
    const state = await runExportAndRun({}, d);
    expect(state.phase).toBe('done');
    if (state.phase !== 'done') return;
    expect(state.bundleId).toBe('com.example.app');
    expect(state.inclusion).toBe('fs-synced');
    expect(state.fileCount).toBe(3); // support + 1 screen + index
    expect(d.writeFiles).toHaveBeenCalledWith(
      '/repo/MyApp/TangoGenerated',
      expect.any(Array),
    );
    expect(d.buildRun).toHaveBeenCalledWith(
      '/repo',
      PROJECT,
      expect.objectContaining({ udid: 'UDID-1', bringForeground: true }),
    );
    expect(getExportRunState()).toEqual(state);
  });

  it('fails on an empty spec without touching the toolchain', async () => {
    const d = deps({ getSpec: () => ({ screens: [] }) });
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'spec' });
    expect(d.buildRun).not.toHaveBeenCalled();
    expect(d.writeFiles).not.toHaveBeenCalled();
  });

  it('fails when no workspace is selected', async () => {
    _setWorkspaceInternal(null, 'unset');
    const state = await runExportAndRun({}, deps());
    expect(state).toMatchObject({ phase: 'error', stage: 'detect' });
  });

  it('fails when no Xcode project is detected', async () => {
    _setIosProjectInternal({ kind: 'none' });
    const state = await runExportAndRun({}, deps());
    expect(state).toMatchObject({ phase: 'error', stage: 'detect' });
  });

  it('fails on ambiguous projects without a scheme', async () => {
    _setIosProjectInternal({
      kind: 'ambiguous',
      candidates: [
        { projectPath: '/repo/A.xcodeproj', projectKind: 'project', schemes: ['A'] },
        { projectPath: '/repo/B.xcodeproj', projectKind: 'project', schemes: ['B'] },
      ],
    });
    const state = await runExportAndRun({}, deps());
    expect(state).toMatchObject({ phase: 'error', stage: 'detect' });

    const resolved = await runExportAndRun({ scheme: 'B' }, deps());
    expect(resolved.phase).toBe('done');
  });

  it('fails when no simulator is booted', async () => {
    const d = deps({ resolveUdid: vi.fn(async () => null) });
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'detect' });
    expect(d.buildRun).not.toHaveBeenCalled();
  });

  it('surfaces write failures as stage=write', async () => {
    const d = deps({
      writeFiles: vi.fn(async () => {
        throw new Error('EACCES');
      }),
    });
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'write', message: 'EACCES' });
  });

  it('maps build failures through with their stage and errors', async () => {
    const d = deps({
      buildRun: vi.fn(async () => ({
        ok: false as const,
        stage: 'build' as const,
        message: 'xcodebuild failed',
        errors: ["error: cannot find 'foo' in scope"],
      })),
    });
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({
      phase: 'error',
      stage: 'build',
      errors: ["error: cannot find 'foo' in scope"],
    });
  });

  it('refuses to start while another run is active', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const d = deps({
      buildRun: vi.fn(async () => {
        await gate;
        return {
          ok: true as const,
          bundleId: 'b',
          pid: 1,
          appPath: '/x',
          durationMs: 1,
        };
      }),
    });
    const first = runExportAndRun({}, d);
    // Give the first run a tick to reach the building phase.
    await new Promise((r) => setTimeout(r, 10));
    const second = await runExportAndRun({}, deps());
    expect(second.phase).toBe('building'); // returned the in-flight state
    release();
    const done = await first;
    expect(done.phase).toBe('done');
  });
});
