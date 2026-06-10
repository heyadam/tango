import { describe, expect, it } from 'vitest';
import {
  groupTranscript,
  type TranscriptItem,
  type ToolItem,
} from './agentTranscript';

const user = (text: string): TranscriptItem => ({ kind: 'user', text });
const assistant = (text: string): TranscriptItem => ({
  kind: 'assistant',
  text,
  streaming: false,
});
const tool = (name: string, detail = ''): ToolItem => ({
  kind: 'tool',
  name,
  detail,
});
const task = (label: string, prompt: string): TranscriptItem => ({
  kind: 'task',
  label,
  prompt,
});

describe('groupTranscript', () => {
  it('returns an empty list for an empty transcript', () => {
    expect(groupTranscript([])).toEqual([]);
  });

  it('wraps a single tool item in a one-element group', () => {
    const items: TranscriptItem[] = [tool('Bash', 'ls')];
    expect(groupTranscript(items)).toEqual([
      { kind: 'tools', items: [tool('Bash', 'ls')] },
    ]);
  });

  it('folds consecutive tools into one group and splits runs on non-tools', () => {
    const items: TranscriptItem[] = [
      user('do the thing'),
      tool('Read', 'a.ts'),
      tool('Edit', 'a.ts'),
      tool('Bash', 'npm test'),
      assistant('done with part one'),
      tool('get_ui_mock'),
      tool('update_ui_node', 'node-1'),
      { kind: 'meta', text: '4.2s · $0.03' },
    ];
    expect(groupTranscript(items)).toEqual([
      user('do the thing'),
      {
        kind: 'tools',
        items: [tool('Read', 'a.ts'), tool('Edit', 'a.ts'), tool('Bash', 'npm test')],
      },
      assistant('done with part one'),
      { kind: 'tools', items: [tool('get_ui_mock'), tool('update_ui_node', 'node-1')] },
      { kind: 'meta', text: '4.2s · $0.03' },
    ]);
  });

  it('passes non-tool items through by reference (memo identity)', () => {
    const a = assistant('hello');
    const u = user('hi');
    const entries = groupTranscript([u, a]);
    expect(entries[0]).toBe(u);
    expect(entries[1]).toBe(a);
  });

  it('keeps tool item references inside groups and does not mutate input', () => {
    const t1 = tool('Read', 'a.ts');
    const t2 = tool('Grep', 'foo');
    const items: TranscriptItem[] = [t1, t2];
    const entries = groupTranscript(items);
    expect(entries).toHaveLength(1);
    const group = entries[0];
    if (group.kind !== 'tools') throw new Error('expected tools group');
    expect(group.items[0]).toBe(t1);
    expect(group.items[1]).toBe(t2);
    expect(items).toEqual([t1, t2]);
  });

  it('passes task items through by reference', () => {
    const t = task('3 variations · Login', 'Call get_ui_mock…');
    const entries = groupTranscript([user('go'), t]);
    expect(entries[1]).toBe(t);
  });

  it('splits a tool run on a task item', () => {
    const t = task('Make it pop · Login', 'In screen "login"…');
    const entries = groupTranscript([tool('get_ui_mock'), t, tool('add_ui_screen', 'login-v1')]);
    expect(entries).toEqual([
      { kind: 'tools', items: [tool('get_ui_mock')] },
      t,
      { kind: 'tools', items: [tool('add_ui_screen', 'login-v1')] },
    ]);
    expect(entries[1]).toBe(t);
  });

  it('handles a transcript that ends mid tool run', () => {
    const items: TranscriptItem[] = [
      user('go'),
      assistant('on it'),
      tool('Bash', 'xcodebuild'),
    ];
    const entries = groupTranscript(items);
    expect(entries).toHaveLength(3);
    expect(entries[2]).toEqual({
      kind: 'tools',
      items: [tool('Bash', 'xcodebuild')],
    });
  });
});
