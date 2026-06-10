// State-machine tests for runUiImport with fully injected deps — no API, no
// filesystem. The workspace slot lives on globalThis; poke it via the
// internal setter (same pattern as iosExportRun.test.ts).

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  applyEmittedScreen,
  findDuplicateNodeId,
  getUiImportState,
  isGeneratedScreenPath,
  lintScreen,
  runUiImport,
  shouldSkipSwiftPath,
  type ImportModelResponse,
  type UiImportDeps,
} from './uiImport';
import { _setWorkspaceInternal } from './workspace';
import type { UIScreen, UISpec } from '@/lib/uiMockProtocol';

const SCREEN: UIScreen = {
  id: 'LoginView',
  title: 'LoginView',
  frame: { w: 390, h: 844 },
  nodes: [
    {
      id: 'loginview-title',
      type: 'heading',
      x: 24,
      y: 80,
      width: 342,
      height: 40,
      text: 'Welcome back',
    },
  ],
};

function toolUse(
  id: string,
  name: string,
  input: unknown,
): ImportModelResponse['content'][number] {
  return { type: 'tool_use', id, name, input } as never;
}

function text(t: string): ImportModelResponse['content'][number] {
  return { type: 'text', text: t, citations: null } as never;
}

function scriptedDeps(
  responses: ImportModelResponse[],
  overrides: Partial<Omit<UiImportDeps, 'setSpec'>> = {},
): UiImportDeps & { setSpec: ReturnType<typeof vi.fn> } {
  let spec: UISpec = { screens: [] };
  const queue = responses.slice();
  const setSpec = vi.fn((next: UISpec) => {
    spec = next;
  });
  return {
    listSwiftFiles: async () => [
      { relPath: 'MyApp/LoginView.swift', bytes: 1200, generated: false },
      { relPath: 'MyApp/Models/User.swift', bytes: 300, generated: false },
    ],
    readFile: async () => 'struct LoginView: View { var body: some View {} }',
    getSpec: () => spec,
    setSpec,
    createMessage: async () => {
      const next = queue.shift();
      if (!next) throw new Error('scripted responses exhausted');
      return next;
    },
    ...overrides,
  };
}

describe('shouldSkipSwiftPath', () => {
  it('skips vendor and test paths', () => {
    expect(shouldSkipSwiftPath('Pods/Lib/Lib.swift')).toBe(true);
    expect(shouldSkipSwiftPath('MyApp/.build/checkouts/x.swift')).toBe(true);
    expect(shouldSkipSwiftPath('MyAppTests/LoginTests.swift')).toBe(true);
    expect(shouldSkipSwiftPath('MyApp/LoginViewTests.swift')).toBe(true);
    expect(shouldSkipSwiftPath('MyApp/Preview Content/P.swift')).toBe(true);
  });

  it('keeps ordinary sources', () => {
    expect(shouldSkipSwiftPath('MyApp/LoginView.swift')).toBe(false);
    expect(shouldSkipSwiftPath('MyApp/Views/Settings.swift')).toBe(false);
  });
});

describe('isGeneratedScreenPath', () => {
  it('accepts TangoGenerated screen files', () => {
    expect(
      isGeneratedScreenPath('MyApp/TangoGenerated/TangoTodoMainScreen.swift'),
    ).toBe(true);
  });

  it('rejects codegen plumbing files', () => {
    expect(
      isGeneratedScreenPath('MyApp/TangoGenerated/TangoSupport.swift'),
    ).toBe(false);
    expect(
      isGeneratedScreenPath('MyApp/TangoGenerated/TangoGeneratedIndex.swift'),
    ).toBe(false);
  });

  it('rejects paths outside TangoGenerated', () => {
    expect(isGeneratedScreenPath('MyApp/LoginView.swift')).toBe(false);
  });
});

describe('applyEmittedScreen', () => {
  it('appends a new screen', () => {
    const next = applyEmittedScreen({ screens: [] }, SCREEN);
    expect(next.screens).toHaveLength(1);
    expect(next.screens[0].id).toBe('LoginView');
  });

  it('replaces a screen with the same id and preserves others', () => {
    const other: UIScreen = { ...SCREEN, id: 'Other', title: 'Other' };
    const updated: UIScreen = { ...SCREEN, title: 'Login (v2)' };
    const next = applyEmittedScreen({ screens: [other, SCREEN] }, updated);
    expect(next.screens.map((s) => s.id)).toEqual(['Other', 'LoginView']);
    expect(next.screens[1].title).toBe('Login (v2)');
  });

  it('preserves the prior sourceFile when the replacement omits it', () => {
    const prior: UIScreen = { ...SCREEN, sourceFile: 'MyApp/LoginView.swift' };
    const updated: UIScreen = { ...SCREEN, title: 'Login (v2)' };
    const next = applyEmittedScreen({ screens: [prior] }, updated);
    expect(next.screens[0].sourceFile).toBe('MyApp/LoginView.swift');
    expect(next.screens[0].title).toBe('Login (v2)');
  });

  it('overwrites the prior sourceFile when the replacement sets one', () => {
    const prior: UIScreen = { ...SCREEN, sourceFile: 'MyApp/Old.swift' };
    const updated: UIScreen = { ...SCREEN, sourceFile: 'MyApp/LoginView.swift' };
    const next = applyEmittedScreen({ screens: [prior] }, updated);
    expect(next.screens[0].sourceFile).toBe('MyApp/LoginView.swift');
  });

  it('appends without provenance when none is given', () => {
    const next = applyEmittedScreen({ screens: [] }, SCREEN);
    expect('sourceFile' in next.screens[0]).toBe(false);
  });
});

describe('lintScreen', () => {
  it('passes a clean screen', () => {
    expect(lintScreen(SCREEN)).toEqual([]);
  });

  it('flags nodes outside the frame', () => {
    const screen: UIScreen = {
      ...SCREEN,
      nodes: [{ ...SCREEN.nodes[0], x: 300, width: 200 }],
    };
    const warnings = lintScreen(screen);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain('outside');
  });

  it('flags single-line text nodes too narrow for their text', () => {
    const screen: UIScreen = {
      ...SCREEN,
      nodes: [
        {
          id: 'n1',
          type: 'text',
          x: 10,
          y: 10,
          width: 60,
          height: 24,
          text: 'Hello, world!', // 13 chars ≈ 120px needed
        },
      ],
    };
    const warnings = lintScreen(screen);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain('clips');
  });

  it('does not flag tall (wrapping) text or generously sized nodes', () => {
    const screen: UIScreen = {
      ...SCREEN,
      nodes: [
        {
          id: 'wrap',
          type: 'text',
          x: 10,
          y: 10,
          width: 100,
          height: 120, // tall → presumed wrapping
          text: 'A long paragraph of body copy that wraps over several lines.',
        },
        {
          id: 'wide',
          type: 'text',
          x: 10,
          y: 200,
          width: 160,
          height: 24,
          text: 'Hello, world!',
        },
      ],
    };
    expect(lintScreen(screen)).toEqual([]);
  });

  it('caps the needed width at the frame width', () => {
    const screen: UIScreen = {
      ...SCREEN,
      frame: { w: 200, h: 400 },
      nodes: [
        {
          id: 'n1',
          type: 'text',
          x: 0,
          y: 10,
          width: 190, // ≥ 95% of frame — as wide as it can reasonably be
          height: 24,
          text: 'a very very long single line of text here',
        },
      ],
    };
    expect(lintScreen(screen)).toEqual([]);
  });
});

describe('findDuplicateNodeId', () => {
  it('finds duplicates and passes unique sets', () => {
    expect(findDuplicateNodeId(SCREEN)).toBeNull();
    const dup: UIScreen = {
      ...SCREEN,
      nodes: [SCREEN.nodes[0], { ...SCREEN.nodes[0] }],
    };
    expect(findDuplicateNodeId(dup)).toBe('loginview-title');
  });
});

describe('runUiImport', () => {
  beforeEach(() => {
    _setWorkspaceInternal('/repo', 'persisted');
  });

  afterEach(() => {
    _setWorkspaceInternal(null, 'unset');
  });

  it('reads files, applies emitted screens, and lands in done', async () => {
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [
          toolUse('t1', 'read_swift_file', { path: 'MyApp/LoginView.swift' }),
        ],
      },
      {
        stop_reason: 'tool_use',
        content: [toolUse('t2', 'emit_screen', { screen: SCREEN })],
      },
      {
        stop_reason: 'end_turn',
        content: [text('Imported LoginView.')],
      },
    ]);
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    if (state.phase !== 'done') return;
    expect(state.screensImported).toBe(1);
    expect(state.filesRead).toBe(1);
    expect(state.summary).toContain('Imported LoginView');
    expect(d.setSpec).toHaveBeenCalledWith({ screens: [SCREEN] });
    expect(getUiImportState()).toEqual(state);
  });

  it('errors when no workspace is selected', async () => {
    _setWorkspaceInternal(null, 'unset');
    const state = await runUiImport(scriptedDeps([]));
    expect(state.phase).toBe('error');
    if (state.phase !== 'error') return;
    expect(state.message).toContain('no workspace');
  });

  it('errors when no Swift sources exist', async () => {
    const d = scriptedDeps([], { listSwiftFiles: async () => [] });
    const state = await runUiImport(d);
    expect(state.phase).toBe('error');
    if (state.phase !== 'error') return;
    expect(state.message).toContain('no Swift sources');
  });

  it('feeds validation failures back as error tool results and recovers', async () => {
    const seenMessages: unknown[][] = [];
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [
          toolUse('t1', 'emit_screen', {
            screen: { id: 'Bad' }, // fails schema validation
          }),
        ],
      },
      {
        stop_reason: 'tool_use',
        content: [toolUse('t2', 'emit_screen', { screen: SCREEN })],
      },
      { stop_reason: 'end_turn', content: [text('done')] },
    ]);
    const inner = d.createMessage;
    d.createMessage = async (params) => {
      seenMessages.push(params.messages.map((m) => m.content));
      return inner(params);
    };
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    if (state.phase !== 'done') return;
    expect(state.screensImported).toBe(1);
    // The second request carries the is_error tool_result for the bad screen.
    const secondTurn = seenMessages[1];
    const lastContent = secondTurn[secondTurn.length - 1] as Array<{
      type: string;
      is_error?: boolean;
    }>;
    expect(lastContent[0].type).toBe('tool_result');
    expect(lastContent[0].is_error).toBe(true);
  });

  it('stamps a valid source_file onto the applied screen', async () => {
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [
          toolUse('t1', 'emit_screen', {
            screen: SCREEN,
            source_file: 'MyApp/LoginView.swift',
          }),
        ],
      },
      { stop_reason: 'end_turn', content: [text('done')] },
    ]);
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    expect(d.setSpec).toHaveBeenCalledWith({
      screens: [{ ...SCREEN, sourceFile: 'MyApp/LoginView.swift' }],
    });
  });

  it('drops a hallucinated source_file with a non-fatal note', async () => {
    const seenMessages: unknown[][] = [];
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [
          toolUse('t1', 'emit_screen', {
            screen: SCREEN,
            source_file: 'MyApp/NotInTheList.swift',
          }),
        ],
      },
      { stop_reason: 'end_turn', content: [text('done')] },
    ]);
    const inner = d.createMessage;
    d.createMessage = async (params) => {
      seenMessages.push(params.messages.map((m) => m.content));
      return inner(params);
    };
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    const applied = d.setSpec.mock.calls[0][0] as UISpec;
    expect('sourceFile' in applied.screens[0]).toBe(false);
    const secondTurn = seenMessages[1];
    const lastContent = secondTurn[secondTurn.length - 1] as Array<{
      type: string;
      content: string;
      is_error?: boolean;
    }>;
    expect(lastContent[0].type).toBe('tool_result');
    expect(lastContent[0].is_error).toBeUndefined();
    expect(lastContent[0].content).toContain(
      'not in the provided file list — provenance not recorded',
    );
  });

  it('treats a TangoGenerated source_file as omitted, keeping prior provenance', async () => {
    const d = scriptedDeps(
      [
        {
          stop_reason: 'tool_use',
          content: [
            toolUse('t1', 'emit_screen', {
              screen: SCREEN,
              source_file: 'TangoGenerated/TangoLoginScreen.swift',
            }),
          ],
        },
        { stop_reason: 'end_turn', content: [text('done')] },
      ],
      {
        getSpec: () => ({
          screens: [{ ...SCREEN, sourceFile: 'MyApp/LoginView.swift' }],
        }),
      },
    );
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    const applied = d.setSpec.mock.calls[0][0] as UISpec;
    expect(applied.screens[0].sourceFile).toBe('MyApp/LoginView.swift');
  });

  it('strips a model-embedded screen.sourceFile without a source_file param', async () => {
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [
          toolUse('t2', 'emit_screen', {
            screen: { ...SCREEN, sourceFile: 'MyApp/LoginView.swift' },
          }),
        ],
      },
      { stop_reason: 'end_turn', content: [text('done')] },
    ]);
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    const applied = d.setSpec.mock.calls[0][0] as UISpec;
    expect('sourceFile' in applied.screens[0]).toBe(false);
  });

  it('rejects reads outside the file list', async () => {
    const d = scriptedDeps([
      {
        stop_reason: 'tool_use',
        content: [toolUse('t1', 'read_swift_file', { path: '/etc/passwd' })],
      },
      {
        stop_reason: 'tool_use',
        content: [toolUse('t2', 'emit_screen', { screen: SCREEN })],
      },
      { stop_reason: 'end_turn', content: [text('done')] },
    ]);
    const readFile = vi.fn(d.readFile);
    d.readFile = readFile;
    const state = await runUiImport(d);
    expect(state.phase).toBe('done');
    expect(readFile).not.toHaveBeenCalled();
  });

  it('errors when the model finishes without emitting screens', async () => {
    const d = scriptedDeps([
      { stop_reason: 'end_turn', content: [text('nothing here looks like a screen')] },
    ]);
    const state = await runUiImport(d);
    expect(state.phase).toBe('error');
    if (state.phase !== 'error') return;
    expect(state.message).toContain('no screens were imported');
  });

  it('surfaces refusals as errors', async () => {
    const d = scriptedDeps([
      { stop_reason: 'refusal', content: [] },
    ]);
    const state = await runUiImport(d);
    expect(state.phase).toBe('error');
  });
});
