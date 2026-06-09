// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { UIMessage } from 'ai';
import {
  chatKey,
  chatStore,
  MAX_BYTES,
  MAX_MESSAGES,
} from './chatStore';

function msg(id: string, role: UIMessage['role'], text: string): UIMessage {
  return {
    id,
    role,
    parts: [{ type: 'text' as const, text }],
  } as unknown as UIMessage;
}

describe('chatKey', () => {
  it('namespaces by workspace path', () => {
    expect(chatKey('/a')).toBe('tango:chat:v1:/a');
    expect(chatKey('/b')).toBe('tango:chat:v1:/b');
    expect(chatKey('/a')).not.toBe(chatKey('/b'));
  });
});

describe('chatStore', () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  afterEach(() => {
    window.localStorage.clear();
  });

  it('round-trips a message list', () => {
    const messages = [msg('1', 'user', 'hi'), msg('2', 'assistant', 'hello')];
    chatStore.save('/ws', messages);
    expect(chatStore.load('/ws')).toEqual(messages);
  });

  it('returns [] when nothing is saved for a workspace', () => {
    expect(chatStore.load('/empty')).toEqual([]);
  });

  it('isolates messages between workspaces', () => {
    chatStore.save('/a', [msg('1', 'user', 'in-a')]);
    chatStore.save('/b', [msg('2', 'user', 'in-b')]);
    expect(chatStore.load('/a')[0]?.id).toBe('1');
    expect(chatStore.load('/b')[0]?.id).toBe('2');
  });

  it('clears one workspace without touching others', () => {
    chatStore.save('/a', [msg('1', 'user', 'a')]);
    chatStore.save('/b', [msg('2', 'user', 'b')]);
    chatStore.clear('/a');
    expect(chatStore.load('/a')).toEqual([]);
    expect(chatStore.load('/b').length).toBe(1);
  });

  it('returns [] for malformed JSON', () => {
    window.localStorage.setItem(chatKey('/ws'), '{not json');
    expect(chatStore.load('/ws')).toEqual([]);
  });

  it('returns [] for valid JSON of the wrong shape', () => {
    window.localStorage.setItem(chatKey('/ws'), '{"messages":1}');
    expect(chatStore.load('/ws')).toEqual([]);
  });

  it('rejects items missing the message-shape fields', () => {
    window.localStorage.setItem(
      chatKey('/ws'),
      JSON.stringify([{ id: 'x', role: 'user' } /* no parts */]),
    );
    expect(chatStore.load('/ws')).toEqual([]);
  });

  it('caps to MAX_MESSAGES, dropping the oldest', () => {
    const big = Array.from({ length: MAX_MESSAGES + 50 }, (_, i) =>
      msg(`m${i}`, 'user', `t${i}`),
    );
    chatStore.save('/ws', big);
    const loaded = chatStore.load('/ws');
    expect(loaded.length).toBe(MAX_MESSAGES);
    expect(loaded[0].id).toBe(`m50`);
    expect(loaded.at(-1)!.id).toBe(`m${MAX_MESSAGES + 49}`);
  });

  it('caps to MAX_BYTES even when message count is small', () => {
    // One huge message ~ 2 * MAX_BYTES, plus a small one.
    const huge = msg('big', 'assistant', 'x'.repeat(MAX_BYTES * 2));
    const small = msg('s', 'user', 'k');
    chatStore.save('/ws', [huge, small]);
    const loaded = chatStore.load('/ws');
    // The huge one gets dropped; only the small one survives.
    expect(loaded.length).toBe(1);
    expect(loaded[0].id).toBe('s');
  });

  it('keeps a single huge message rather than dropping it to []', () => {
    // The trim loop guards on `trimmed.length > 1`, so the last surviving
    // message is preserved even if it alone exceeds MAX_BYTES. Regressing
    // this would silently lose the user's most recent turn.
    const onlyHuge = msg('giant', 'assistant', 'x'.repeat(MAX_BYTES * 3));
    chatStore.save('/ws', [onlyHuge]);
    const loaded = chatStore.load('/ws');
    expect(loaded.length).toBe(1);
    expect(loaded[0].id).toBe('giant');
  });

  it('is a no-op for empty workspacePath', () => {
    chatStore.save('', [msg('1', 'user', 'x')]);
    expect(chatStore.load('')).toEqual([]);
    expect(window.localStorage.length).toBe(0);
  });
});
