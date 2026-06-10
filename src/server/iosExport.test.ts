// Unit tests for the in-place export plumbing: source-root resolution, the
// splice/create/cleanup orchestration (applyInPlaceExport), project scanning,
// and provenance restamping — all against an in-memory ExportFs.

import { describe, expect, it } from 'vitest';
import {
  BACKUP_DIR,
  GENERATED_DIR_NAME,
  applyInPlaceExport,
  cleanupLegacyGenerated,
  patchScreenProvenance,
  projectReferencesTypes,
  resolveSourceRoot,
  scanProjectTypes,
  type ExportFs,
} from './iosExport';
import { hashSource } from './sourceHash';
import { BODY_MARKER } from '@/lib/swiftScan';
import type { IosProject } from './iosBuild';
import type { UIScreen, UISpec } from '@/lib/uiMockProtocol';

// ── in-memory fs ────────────────────────────────────────────────────────────

function memFs(initial: Record<string, string> = {}) {
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
      const out = new Map<string, boolean>(); // name → isDir
      for (const k of files.keys()) {
        if (!k.startsWith(prefix)) continue;
        const rest = k.slice(prefix.length);
        const top = rest.split('/')[0];
        out.set(top, out.get(top) || rest.includes('/'));
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

function project(path = '/repo/MyApp.xcodeproj'): IosProject {
  return {
    projectPath: path,
    projectKind: path.endsWith('.xcworkspace') ? 'workspace' : 'project',
    scheme: 'AppScheme',
    bundleId: null,
    configurations: ['Debug', 'Release'],
  };
}

const CONTENT_VIEW = `import SwiftUI

struct TodoListView: View {
  @State private var newTask = ""
  var body: some View {
    VStack { Text("hand-written") }
  }
  func helper() -> Int { 7 }
}

struct AuthView: View {
  var body: some View {
    Text("auth")
  }
}
`;

function screen(partial: Partial<UIScreen> & Pick<UIScreen, 'id'>): UIScreen {
  return {
    title: partial.id,
    frame: { w: 390, h: 844 },
    nodes: [
      {
        id: `${partial.id}-t`,
        type: 'text',
        x: 10,
        y: 20,
        width: 100,
        height: 24,
        text: 'hello',
      },
    ],
    ...partial,
  };
}

const WS = '/repo';
const SRC_ROOT = '/repo/MyApp';
const PROJ_DIR = '/repo';

function run(spec: UISpec, fsx: ExportFs) {
  return applyInPlaceExport({
    spec,
    workspace: WS,
    sourceRoot: SRC_ROOT,
    projectDir: PROJ_DIR,
    fsx,
  });
}

// ── resolveSourceRoot ───────────────────────────────────────────────────────

describe('resolveSourceRoot', () => {
  it('targets <projDir>/<stem> and detects fs-synced projects', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/App.swift': '//',
      '/repo/MyApp.xcodeproj/project.pbxproj':
        'objects { PBXFileSystemSynchronizedRootGroup }',
    });
    const result = await resolveSourceRoot(project(), fsx);
    expect(result.sourceRoot).toBe('/repo/MyApp');
    expect(result.inclusion).toBe('fs-synced');
  });

  it('reports manual-add-required for legacy PBXGroup projects', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/App.swift': '//',
      '/repo/MyApp.xcodeproj/project.pbxproj': 'objects { PBXGroup }',
    });
    const result = await resolveSourceRoot(project(), fsx);
    expect(result.inclusion).toBe('manual-add-required');
  });

  it('reads the sibling .xcodeproj pbxproj for workspaces', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/App.swift': '//',
      '/repo/MyApp.xcodeproj/project.pbxproj':
        'PBXFileSystemSynchronizedRootGroup',
    });
    const result = await resolveSourceRoot(project('/repo/MyApp.xcworkspace'), fsx);
    expect(result.sourceRoot).toBe('/repo/MyApp');
    expect(result.inclusion).toBe('fs-synced');
  });

  it('falls back to the scheme dir, then the project dir', async () => {
    const byScheme = await resolveSourceRoot(
      project(),
      memFs({ '/repo/AppScheme/App.swift': '//' }).fsx,
    );
    expect(byScheme.sourceRoot).toBe('/repo/AppScheme');

    const fallback = await resolveSourceRoot(project(), memFs({}).fsx);
    expect(fallback.sourceRoot).toBe('/repo');
    expect(fallback.inclusion).toBe('manual-add-required');
  });
});

// ── applyInPlaceExport: linked screens ──────────────────────────────────────

describe('applyInPlaceExport — linked screens', () => {
  const linkedSpec = (hash?: string): UISpec => ({
    screens: [
      screen({
        id: 'TodoListView',
        sourceFile: 'MyApp/ContentView.swift',
        sourceHash: hash ?? hashSource(CONTENT_VIEW),
      }),
    ],
  });

  it('replaces only the struct body, in place', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const out = await run(linkedSpec(), fsx);

    expect(out.results).toEqual([
      {
        screenId: 'TodoListView',
        file: 'MyApp/ContentView.swift',
        struct: 'TodoListView',
        action: 'updated',
      },
    ]);
    const next = files.get('/repo/MyApp/ContentView.swift')!;
    expect(next).toContain(BODY_MARKER);
    expect(next).toContain('ZStack(alignment: .topLeading)');
    expect(next).not.toContain('hand-written');
    // Everything outside the body survives byte-for-byte.
    expect(next).toContain('@State private var newTask = ""');
    expect(next).toContain('func helper() -> Int { 7 }');
    expect(next).toContain('Text("auth")');
  });

  it('backs up the pre-export content and restamps provenance to the new hash', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const out = await run(linkedSpec(), fsx);

    expect(out.backedUp).toEqual(['MyApp/ContentView.swift']);
    expect(files.get(`/repo/${BACKUP_DIR}/MyApp/ContentView.swift`)).toBe(
      CONTENT_VIEW,
    );
    const next = files.get('/repo/MyApp/ContentView.swift')!;
    expect(out.provenance.get('TodoListView')).toEqual({
      sourceFile: 'MyApp/ContentView.swift',
      sourceHash: hashSource(next),
    });
  });

  it('clears the previous backup dir at the start of each run', async () => {
    const { files, fsx } = memFs({
      '/repo/MyApp/ContentView.swift': CONTENT_VIEW,
      [`/repo/${BACKUP_DIR}/MyApp/Stale.swift`]: 'old backup',
    });
    await run(linkedSpec(), fsx);
    expect(files.has(`/repo/${BACKUP_DIR}/MyApp/Stale.swift`)).toBe(false);
  });

  it('splices several screens sharing one file in a single write', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const spec: UISpec = {
      screens: [
        screen({
          id: 'TodoListView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: hashSource(CONTENT_VIEW),
        }),
        screen({
          id: 'AuthView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: hashSource(CONTENT_VIEW),
        }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results.map((r) => r.action)).toEqual(['updated', 'updated']);
    const next = files.get('/repo/MyApp/ContentView.swift')!;
    expect(next).toContain('screen=TodoListView');
    expect(next).toContain('screen=AuthView');
    expect(out.backedUp).toEqual(['MyApp/ContentView.swift']);
    // Both screens restamp to the SAME final-content hash.
    expect(out.provenance.get('TodoListView')!.sourceHash).toBe(hashSource(next));
    expect(out.provenance.get('AuthView')!.sourceHash).toBe(hashSource(next));
  });

  it('is idempotent: a second export of the same design is "unchanged" with no write', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const first = await run(linkedSpec(), fsx);
    const afterFirst = files.get('/repo/MyApp/ContentView.swift')!;
    const restamped = first.provenance.get('TodoListView')!;

    const spec2: UISpec = {
      screens: [
        screen({
          id: 'TodoListView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: restamped.sourceHash,
        }),
      ],
    };
    const second = await run(spec2, fsx);
    expect(second.results[0].action).toBe('unchanged');
    expect(second.backedUp).toEqual([]);
    expect(files.get('/repo/MyApp/ContentView.swift')).toBe(afterFirst);
  });

  it('skips a hand-edited file (stale hash, unmarked body) without touching it', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const out = await run(linkedSpec('0123456789abcdef'), fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(out.results[0].reason).toContain('changed since this screen was imported');
    expect(files.get('/repo/MyApp/ContentView.swift')).toBe(CONTENT_VIEW);
    expect(out.provenance.size).toBe(0);
    expect(out.backedUp).toEqual([]);
  });

  it('overwrites a stale file when the body carries the tango:body marker', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    // First export stamps the marker…
    await run(linkedSpec(), fsx);
    const marked = files.get('/repo/MyApp/ContentView.swift')!;
    // …then someone edits a DIFFERENT part of the file (hash now stale, body
    // still marker-carrying).
    files.set(
      '/repo/MyApp/ContentView.swift',
      marked.replace('func helper() -> Int { 7 }', 'func helper() -> Int { 8 }'),
    );
    const spec: UISpec = {
      screens: [
        {
          ...screen({ id: 'TodoListView' }),
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: 'feedfacefeedface', // stale on purpose
          nodes: [
            {
              id: 'TodoListView-t',
              type: 'text',
              x: 10,
              y: 20,
              width: 100,
              height: 24,
              text: 'redesigned',
            },
          ],
        },
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('updated');
    const next = files.get('/repo/MyApp/ContentView.swift')!;
    expect(next).toContain('Text("redesigned")');
    expect(next).toContain('func helper() -> Int { 8 }'); // their edit survives
    expect(next).toContain(BODY_MARKER);
  });

  it('exports legacy screens with no sourceHash (canvas is the only truth)', async () => {
    const { fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const spec: UISpec = {
      screens: [
        screen({ id: 'TodoListView', sourceFile: 'MyApp/ContentView.swift' }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('updated');
  });

  it('skips when the source file is missing', async () => {
    const { fsx } = memFs({});
    const out = await run(linkedSpec(), fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(out.results[0].reason).toContain('missing');
  });

  it('skips when the struct cannot be found, naming the candidates tried', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/ContentView.swift':
        'struct SomethingElse: View { var body: some View { Text("x") } }',
    });
    const out = await run(linkedSpec(), fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(out.results[0].reason).toContain('TodoListView');
    expect(out.results[0].reason).toContain('re-import');
  });

  it('refuses provenance paths that escape the workspace', async () => {
    const { fsx } = memFs({ '/evil.swift': 'struct E {}' });
    const spec: UISpec = {
      screens: [screen({ id: 'E', sourceFile: '../evil.swift' })],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(out.results[0].reason).toContain('escapes the workspace');
  });

  it('never lets two screens claim the same struct in one file', async () => {
    const { fsx } = memFs({ '/repo/MyApp/ContentView.swift': CONTENT_VIEW });
    const spec: UISpec = {
      screens: [
        screen({
          id: 'TodoListView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: hashSource(CONTENT_VIEW),
        }),
        screen({
          id: 'todo-list-view',
          title: 'TodoListView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: hashSource(CONTENT_VIEW),
        }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('updated');
    expect(out.results[1].action).toBe('skipped');
  });
});

// ── applyInPlaceExport: navigation-shell guard ──────────────────────────────

const SHELL_CONTENT_VIEW = `import SwiftUI

struct ContentView: View {
  var body: some View {
    TabView {
      TodoListView().tabItem { Label("Tasks", systemImage: "checklist") }
      AuthView().tabItem { Label("Account", systemImage: "person") }
    }
  }
}

struct TodoListView: View {
  var body: some View {
    NavigationStack {
      Text("todos")
    }
  }
}

struct AuthView: View {
  var body: some View {
    Text("auth")
  }
}
`;

describe('applyInPlaceExport — navigation-shell guard', () => {
  const shellSpec = (): UISpec => ({
    screens: ['ContentView', 'TodoListView', 'AuthView'].map((id) =>
      screen({
        id,
        sourceFile: 'MyApp/ContentView.swift',
        sourceHash: hashSource(SHELL_CONTENT_VIEW),
      }),
    ),
  });

  it('skips the shell (it hosts other canvas screens) and exports the destinations', async () => {
    const { files, fsx } = memFs({
      '/repo/MyApp/ContentView.swift': SHELL_CONTENT_VIEW,
    });
    const out = await run(shellSpec(), fsx);
    const byId = new Map(out.results.map((r) => [r.screenId, r]));
    expect(byId.get('ContentView')!.action).toBe('skipped');
    expect(byId.get('ContentView')!.reason).toContain('navigation shell');
    // A real screen wrapping itself in a NavigationStack still exports.
    expect(byId.get('TodoListView')!.action).toBe('updated');
    expect(byId.get('AuthView')!.action).toBe('updated');
    const next = files.get('/repo/MyApp/ContentView.swift')!;
    // The shell's TabView body survives byte-for-byte.
    expect(next).toContain('TabView {');
    expect(next).toContain('.tabItem { Label("Tasks", systemImage: "checklist") }');
    expect(next).toContain('screen=TodoListView');
    expect(out.provenance.has('ContentView')).toBe(false);
  });

  it('skips an unmarked TabView body even when the hosted views are not canvas screens', async () => {
    const src = `import SwiftUI
struct RootView: View {
  var body: some View {
    TabView { HomePane() ; SettingsPane() }
  }
}
`;
    const { files, fsx } = memFs({ '/repo/MyApp/Root.swift': src });
    const spec: UISpec = {
      screens: [
        screen({
          id: 'RootView',
          sourceFile: 'MyApp/Root.swift',
          sourceHash: hashSource(src),
        }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(out.results[0].reason).toContain('TabView');
    expect(files.get('/repo/MyApp/Root.swift')).toBe(src);
  });

  it('does not trip on TabView mentioned in strings, comments, or as a prefix', async () => {
    const src = `import SwiftUI
struct HomeView: View {
  // A TabView used to live here.
  let note = "TabView is gone"
  var body: some View {
    Text("home").tabViewStyle(.page)
  }
}
`;
    const { fsx } = memFs({ '/repo/MyApp/Home.swift': src });
    const spec: UISpec = {
      screens: [
        screen({
          id: 'HomeView',
          sourceFile: 'MyApp/Home.swift',
          sourceHash: hashSource(src),
        }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0].action).toBe('updated');
  });

  it('still regenerates a MARKED body freely (markers outrank the shell guard)', async () => {
    const { files, fsx } = memFs({
      '/repo/MyApp/ContentView.swift': SHELL_CONTENT_VIEW,
    });
    // First export marks TodoListView's body…
    await run(shellSpec(), fsx);
    const afterFirst = files.get('/repo/MyApp/ContentView.swift')!;
    // …second export re-splices it without tripping any guard.
    const spec2: UISpec = {
      screens: [
        screen({
          id: 'TodoListView',
          sourceFile: 'MyApp/ContentView.swift',
          sourceHash: hashSource(afterFirst),
        }),
      ],
    };
    const out = await run(spec2, fsx);
    expect(out.results[0].action).toBe('unchanged');
  });
});

// ── applyInPlaceExport: new screens ─────────────────────────────────────────

describe('applyInPlaceExport — canvas-born screens', () => {
  it('creates a new file at the source root and links the screen to it', async () => {
    const { files, fsx } = memFs({ '/repo/MyApp/App.swift': 'struct MyApp {}' });
    const out = await run({ screens: [screen({ id: 'settings' })] }, fsx);

    expect(out.results).toEqual([
      {
        screenId: 'settings',
        file: 'MyApp/SettingsScreen.swift',
        struct: 'SettingsScreen',
        action: 'created',
      },
    ]);
    const content = files.get('/repo/MyApp/SettingsScreen.swift')!;
    expect(content).toContain('struct SettingsScreen: View {');
    expect(content).toContain(BODY_MARKER);
    expect(out.provenance.get('settings')).toEqual({
      sourceFile: 'MyApp/SettingsScreen.swift',
      sourceHash: hashSource(content),
    });
  });

  it('names around the project’s declared types', async () => {
    const { files, fsx } = memFs({
      '/repo/MyApp/Old.swift':
        'struct SettingsScreen: View { var body: some View { Text("o") } }',
    });
    const out = await run({ screens: [screen({ id: 'settings' })] }, fsx);
    expect(out.results[0].struct).toBe('SettingsScreen2');
    expect(files.has('/repo/MyApp/SettingsScreen2.swift')).toBe(true);
  });

  it('treats a legacy TangoGenerated sourceFile as unlinked and re-homes the screen', async () => {
    const { files, fsx } = memFs({
      [`/repo/MyApp/${GENERATED_DIR_NAME}/TangoSettingsScreen.swift`]: MARKED,
      '/repo/MyApp/App.swift': 'struct MyApp {}',
    });
    const spec: UISpec = {
      screens: [
        screen({
          id: 'settings',
          sourceFile: `MyApp/${GENERATED_DIR_NAME}/TangoSettingsScreen.swift`,
          sourceHash: 'cafebabecafebabe',
        }),
      ],
    };
    const out = await run(spec, fsx);
    expect(out.results[0]).toMatchObject({
      action: 'created',
      file: 'MyApp/SettingsScreen.swift',
    });
    expect(out.provenance.get('settings')!.sourceFile).toBe(
      'MyApp/SettingsScreen.swift',
    );
    // The legacy folder's marked file is cleaned up (nothing references it).
    expect(files.has(`/repo/MyApp/${GENERATED_DIR_NAME}/TangoSettingsScreen.swift`)).toBe(false);
  });

  it('skips instead of overwriting an existing same-name file', async () => {
    const { files, fsx } = memFs({
      // The file exists but declares no type (so the name scan can't see it).
      '/repo/MyApp/SettingsScreen.swift': '// reserved, no decls',
    });
    const out = await run({ screens: [screen({ id: 'settings' })] }, fsx);
    expect(out.results[0].action).toBe('skipped');
    expect(files.get('/repo/MyApp/SettingsScreen.swift')).toBe('// reserved, no decls');
  });
});

// ── legacy TangoGenerated cleanup ───────────────────────────────────────────

const MARKED = `// Generated by tango — DO NOT EDIT.
// tango:generated v=1 screen=old
struct TangoOldScreen: View {}`;

describe('cleanupLegacyGenerated', () => {
  it('removes marked files when nothing references the generated types', async () => {
    const { files, fsx } = memFs({
      [`/repo/MyApp/${GENERATED_DIR_NAME}/TangoOldScreen.swift`]: MARKED,
      [`/repo/MyApp/${GENERATED_DIR_NAME}/notes.txt`]: 'keep me',
      '/repo/MyApp/App.swift': 'struct MyApp { }',
    });
    const out = await cleanupLegacyGenerated(SRC_ROOT, PROJ_DIR, fsx);
    expect(out).toEqual({ removed: 1, kept: false });
    expect(files.has(`/repo/MyApp/${GENERATED_DIR_NAME}/TangoOldScreen.swift`)).toBe(false);
    expect(files.has(`/repo/MyApp/${GENERATED_DIR_NAME}/notes.txt`)).toBe(true);
  });

  it('keeps everything when user code still references the old views', async () => {
    const { files, fsx } = memFs({
      [`/repo/MyApp/${GENERATED_DIR_NAME}/TangoOldScreen.swift`]: MARKED,
      '/repo/MyApp/App.swift':
        'struct MyApp { var body: some Scene { WindowGroup { TangoOldScreen() } } }',
    });
    const out = await cleanupLegacyGenerated(SRC_ROOT, PROJ_DIR, fsx);
    expect(out).toEqual({ removed: 0, kept: true });
    expect(files.has(`/repo/MyApp/${GENERATED_DIR_NAME}/TangoOldScreen.swift`)).toBe(true);
  });

  it('never deletes unmarked files in the dir', async () => {
    const { files, fsx } = memFs({
      [`/repo/MyApp/${GENERATED_DIR_NAME}/UserFile.swift`]: 'struct UserThing {}',
      '/repo/MyApp/App.swift': 'struct MyApp {}',
    });
    const out = await cleanupLegacyGenerated(SRC_ROOT, PROJ_DIR, fsx);
    expect(out.removed).toBe(0);
    expect(files.has(`/repo/MyApp/${GENERATED_DIR_NAME}/UserFile.swift`)).toBe(true);
  });

  it('is a no-op when the dir does not exist', async () => {
    const { fsx } = memFs({ '/repo/MyApp/App.swift': '//' });
    expect(await cleanupLegacyGenerated(SRC_ROOT, PROJ_DIR, fsx)).toEqual({
      removed: 0,
      kept: false,
    });
  });
});

// ── project scanning ────────────────────────────────────────────────────────

describe('scanProjectTypes / projectReferencesTypes', () => {
  it('collects declared types from user sources only', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/App.swift': 'struct MyApp {}\nenum Tab { case a }',
      '/repo/MyApp/Models.swift': 'class Store {}\n// struct Commented {}',
      [`/repo/MyApp/${GENERATED_DIR_NAME}/TangoOld.swift`]: 'struct TangoOld {}',
      '/repo/Pods/Dep.swift': 'struct PodThing {}',
    });
    const types = await scanProjectTypes(PROJ_DIR, fsx);
    expect(types.has('MyApp')).toBe(true);
    expect(types.has('Tab')).toBe(true);
    expect(types.has('Store')).toBe(true);
    expect(types.has('Commented')).toBe(false);
    expect(types.has('TangoOld')).toBe(false);
    expect(types.has('PodThing')).toBe(false);
  });

  it('finds references and skips tango-marked files', async () => {
    const { fsx } = memFs({
      '/repo/MyApp/App.swift': 'WindowGroup { HomeView() }',
      '/repo/MyApp/Generated.swift': `// tango:generated v=1\nlet x = OtherView()`,
    });
    expect(await projectReferencesTypes(PROJ_DIR, ['HomeView'], fsx)).toBe(true);
    expect(await projectReferencesTypes(PROJ_DIR, ['OtherView'], fsx)).toBe(false);
    expect(await projectReferencesTypes(PROJ_DIR, [], fsx)).toBe(false);
  });
});

// ── patchScreenProvenance ───────────────────────────────────────────────────

describe('patchScreenProvenance', () => {
  const spec: UISpec = {
    screens: [
      screen({ id: 'a', sourceFile: 'A.swift', sourceHash: 'aaaa' }),
      screen({ id: 'b' }),
    ],
  };

  it('patches only the listed screens, preserving the others’ identity', () => {
    const patched = patchScreenProvenance(
      spec,
      new Map([['b', { sourceFile: 'B.swift', sourceHash: 'bbbb' }]]),
    );
    expect(patched).not.toBeNull();
    expect(patched!.screens[0]).toBe(spec.screens[0]);
    expect(patched!.screens[1]).toMatchObject({
      sourceFile: 'B.swift',
      sourceHash: 'bbbb',
    });
  });

  it('returns null when nothing changes', () => {
    expect(
      patchScreenProvenance(
        spec,
        new Map([['a', { sourceFile: 'A.swift', sourceHash: 'aaaa' }]]),
      ),
    ).toBeNull();
    expect(patchScreenProvenance(spec, new Map())).toBeNull();
  });
});
