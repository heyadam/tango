import { describe, expect, it } from 'vitest';
import {
  PRESET_PREFILLS,
  buildCustomPrompt,
  buildVariationsPrompt,
  taskLabel,
} from './agentTaskPrompts';
import type { AgentTask } from './terminalBus';

const screenScope: AgentTask['scope'] = {
  kind: 'screen',
  screenId: 'login',
  screenTitle: 'Login',
};

const nodesScope: AgentTask['scope'] = {
  kind: 'nodes',
  screenId: 'login',
  screenTitle: 'Login',
  nodeIds: ['login-title', 'login-cta'],
};

describe('buildVariationsPrompt', () => {
  it('pins the load-bearing safety phrases', () => {
    const prompt = buildVariationsPrompt(screenScope);
    expect(prompt).toContain('get_ui_mock');
    expect(prompt).toContain('add_ui_screen');
    expect(prompt).toContain('NEVER call set_ui_mock or clear_ui_mock');
    expect(prompt).toContain('never modify the original');
    expect(prompt).toContain('globally unique');
    expect(prompt).toContain('-v1');
    expect(prompt).toContain('· v1');
  });

  it('pins the parallel fan-out instructions for screen variations', () => {
    const prompt = buildVariationsPrompt(screenScope);
    expect(prompt).toContain('Task tool IN PARALLEL');
    expect(prompt).toContain('a single message');
    expect(prompt).toContain('exactly one add_ui_screen call');
    expect(prompt).toContain('repeat the hard rules verbatim');
  });

  it('interpolates the scope ids and title into the fresh-id and titling rules', () => {
    const prompt = buildVariationsPrompt(screenScope);
    expect(prompt).toContain('read screen "login" ("Login")');
    expect(prompt).toContain('"login-v1", "login-v2", "login-v3"');
    expect(prompt).toContain('"Login · v1", "· v2", "· v3"');
    expect(prompt).toContain("Do not copy the original screen's sourceFile");
  });

  it('node scope varies the selected elements in one comparison screen, pinning the safety phrases', () => {
    const prompt = buildVariationsPrompt(nodesScope);
    expect(prompt).toContain('The user selected these element node(s): login-title, login-cta.');
    expect(prompt).toContain('SELECTED ELEMENT(S) ONLY — not the whole screen');
    expect(prompt).toContain('ONE new comparison screen (a single add_ui_screen call)');
    expect(prompt).toContain('NEVER call set_ui_mock or clear_ui_mock');
    expect(prompt).toContain('never modify the original');
    expect(prompt).toContain('"login-el-v1"');
    expect(prompt).toContain('"Login · element variations"');
    expect(prompt).toContain('globally unique');
    expect(prompt).toContain('do not set sourceFile');
    expect(prompt).not.toContain('one add_ui_screen call per variation');
  });

  it('falls back to whole-screen variations when nodeIds is empty or missing', () => {
    for (const scope of [
      { ...nodesScope, nodeIds: [] },
      { ...nodesScope, nodeIds: undefined },
    ]) {
      const prompt = buildVariationsPrompt(scope);
      expect(prompt).not.toContain('SELECTED ELEMENT(S)');
      expect(prompt).toContain('"login-v1", "login-v2", "login-v3"');
    }
  });
});

describe('buildCustomPrompt', () => {
  it('wraps trimmed user text with screen context and tool steering', () => {
    const prompt = buildCustomPrompt(screenScope, '  Make the header bolder  ');
    expect(prompt).toContain('In screen "login" ("Login")');
    expect(prompt).toContain('Make the header bolder');
    expect(prompt).not.toContain('  Make the header bolder  ');
    expect(prompt).toContain('Call get_ui_mock first');
    expect(prompt).toContain('update_ui_node / add_ui_nodes / remove_ui_node / reorder_ui_node');
    expect(prompt).toContain('add_ui_screen');
    expect(prompt).toContain('Avoid set_ui_mock');
  });

  it('names the selected node ids for a node scope', () => {
    const prompt = buildCustomPrompt(nodesScope, 'Tighten this up');
    expect(prompt).toContain(
      'The user selected node(s) login-title, login-cta in screen "login" ("Login")',
    );
    expect(prompt).toContain('Tighten this up');
  });
});

describe('taskLabel', () => {
  it('formats variations labels from the screen title', () => {
    expect(taskLabel(screenScope, 'variations')).toBe('3 variations · Login');
    expect(taskLabel(nodesScope, 'variations')).toBe('3 element variations · Login');
  });

  it('uses the first line of the user text for custom labels', () => {
    expect(taskLabel(screenScope, 'custom', 'Make it pop\nwith more detail below')).toBe(
      'Make it pop · Login',
    );
  });

  it('truncates long custom text to 40 chars with an ellipsis', () => {
    expect(taskLabel(screenScope, 'custom', 'x'.repeat(60))).toBe(
      `${'x'.repeat(40)}… · Login`,
    );
  });
});

describe('PRESET_PREFILLS', () => {
  it('exposes the chip rosters for both scopes', () => {
    expect(Object.keys(PRESET_PREFILLS.screen)).toEqual(['Restyle', 'Simplify', 'Rearrange']);
    expect(Object.keys(PRESET_PREFILLS.nodes)).toEqual(['Restyle', 'Polish copy', 'Rearrange']);
  });
});
