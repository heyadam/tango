// State-machine tests for runExportAndRun with fully injected deps — no
// xcodebuild, no filesystem. The workspace/iOS-project slots live on
// globalThis, so we poke them via the internal setters.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  getExportRunState,
  runExportAndRun,
  type ExportFs,
} from './iosExport';
import { hashSource } from './sourceHash';
import {
  _setIosProjectInternal,
  _setWorkspaceInternal,
} from './workspace';
import type { UISpec } from '@/lib/uiMockProtocol';
import type { IosProject } from './iosBuild';

const CONTENT_VIEW = `import SwiftUI

struct S1View: View {
  var body: some View {
    Text("hand-written")
  }
}
`;

const SPEC: UISpec = {
  screens: [
    {
      id: 'S1View',
      title: 'S1View',
      frame: { w: 100, h: 100 },
      nodes: [
        { id: 'n1', type: 'text', x: 0, y: 0, width: 10, height: 10, text: 'x' },
      ],
      sourceFile: 'MyApp/ContentView.swift',
      sourceHash: hashSource(CONTENT_VIEW),
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

function memFs(initial: Record<string, string>) {
  const files = new Map<string, string>(Object.entries(initial));
  const fsx: ExportFs = {
    readFile: async (p) => {
      const v = files.get(p);
      if (v === undefined) throw new Error(`ENOENT: ${p}`);
      return v;
    },
    writeFile: async (p, c) => {
      files.set(p, c);
    },
    exists: async (p) =>
      files.has(p) || [...files.keys()].some((k) => k.startsWith(`${p}/`)),
    readdir: async (p) => {
      const prefix = `${p}/`;
      const out = new Map<string, boolean>();
      for (const k of files.keys()) {
        if (!k.startsWith(prefix)) continue;
        const rest = k.slice(prefix.length);
        out.set(rest.split('/')[0], out.get(rest.split('/')[0]) || rest.includes('/'));
      }
      return [...out].map(([name, dir]) => ({ name, dir, file: !dir }));
    },
    unlink: async (p) => {
      files.delete(p);
    },
    rmdirIfEmpty: async () => {},
    rmrf: async (p) => {
      const prefix = `${p}/`;
      for (const k of [...files.keys()]) {
        if (k === p || k.startsWith(prefix)) files.delete(k);
      }
    },
  };
  return { files, fsx };
}

function deps(overrides: Partial<Parameters<typeof runExportAndRun>[1]> = {}) {
  const mem = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
  return {
    files: mem.files,
    getSpec: () => SPEC,
    setSpec: vi.fn(),
    buildRun: vi.fn(async () => ({
      ok: true as const,
      bundleId: 'com.example.app',
      pid: 123,
      appPath: '/dd/MyApp.app',
      durationMs: 1000,
    })),
    resolveUdid: vi.fn(async () => 'UDID-1'),
    resolveRoot: vi.fn(async () => ({
      sourceRoot: '/repo/MyApp',
      inclusion: 'fs-synced' as const,
    })),
    fsx: mem.fsx,
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
  });

  it('runs the full pipeline to done: splice → restamp → build → launch', async () => {
    const d = deps();
    const state = await runExportAndRun({}, d);
    expect(state.phase).toBe('done');
    if (state.phase !== 'done') return;
    expect(state.bundleId).toBe('com.example.app');
    expect(state.inclusion).toBe('fs-synced');
    expect(state.results).toEqual([
      {
        screenId: 'S1View',
        file: 'MyApp/ContentView.swift',
        struct: 'S1View',
        action: 'updated',
      },
    ]);
    // The user's source got the spliced body…
    const next = d.files.get('/repo/MyApp/ContentView.swift')!;
    expect(next).toContain('tango:body');
    expect(next).not.toContain('hand-written');
    // …and provenance was restamped on the live spec before the build.
    const setSpec = d.setSpec as ReturnType<typeof vi.fn>;
    expect(setSpec).toHaveBeenCalledTimes(1);
    const restamped = setSpec.mock.calls[0][0] as UISpec;
    expect(restamped.screens[0].sourceHash).toBe(hashSource(next));
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

  it('fails when no simulator is booted, after writing but before building', async () => {
    const d = deps({ resolveUdid: vi.fn(async () => null) });
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'detect' });
    expect(d.buildRun).not.toHaveBeenCalled();
  });

  it('fails with stage=write when every screen is skipped, listing reasons', async () => {
    const d = deps();
    // Hand-edit the source so the stale guard skips the only screen.
    d.files.set('/repo/MyApp/ContentView.swift', `${CONTENT_VIEW}\n// edited`);
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'write' });
    if (state.phase !== 'error') return;
    expect(state.errors[0]).toContain('S1View');
    expect(state.errors[0]).toContain('refresh');
    expect(d.buildRun).not.toHaveBeenCalled();
    expect(d.setSpec).not.toHaveBeenCalled();
  });

  it('surfaces write failures as stage=write', async () => {
    const d = deps();
    d.fsx.writeFile = async () => {
      throw new Error('EACCES');
    };
    const state = await runExportAndRun({}, d);
    expect(state).toMatchObject({ phase: 'error', stage: 'write', message: 'EACCES' });
  });

  it('maps build failures through with their stage, errors, and the backup hint', async () => {
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
    if (state.phase !== 'error') return;
    expect(state.message).toContain('export-backup');
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
