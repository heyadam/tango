// @vitest-environment happy-dom
import { describe, expect, it, vi } from 'vitest';
import { chatBus } from './chatBus';

describe('chatBus', () => {
  it('dispatches send to all registered listeners', () => {
    const a = vi.fn();
    const b = vi.fn();
    const offA = chatBus._onSend(a);
    const offB = chatBus._onSend(b);
    chatBus.send('hello');
    expect(a).toHaveBeenCalledWith('hello', { autosubmit: true });
    expect(b).toHaveBeenCalledWith('hello', { autosubmit: true });
    offA();
    offB();
  });

  it('passes through caller-supplied opts', () => {
    const seen = vi.fn();
    const off = chatBus._onSend(seen);
    chatBus.send('hi', { autosubmit: false });
    expect(seen).toHaveBeenCalledWith('hi', { autosubmit: false });
    off();
  });

  it('unsubscribe stops further deliveries', () => {
    const cb = vi.fn();
    const off = chatBus._onSend(cb);
    chatBus.send('one');
    off();
    chatBus.send('two');
    expect(cb).toHaveBeenCalledTimes(1);
    expect(cb).toHaveBeenCalledWith('one', { autosubmit: true });
  });

  it('is a no-op when no listeners are registered', () => {
    // Just confirming this doesn't throw.
    expect(() => chatBus.send('lonely')).not.toThrow();
  });
});
