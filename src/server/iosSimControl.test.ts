import { describe, it, expect } from 'vitest';
import {
  type AxSnapshot,
  axCenterNorm,
  firstSseJson,
  gestureFrame,
  isValidButtonName,
  isValidOrientation,
  ROTATE_ORIENTATIONS,
  toInspectResult,
  validateNormalized,
} from './iosSimControl';

describe('validateNormalized', () => {
  it('accepts coordinates inside 0..1, including the bounds', () => {
    expect(validateNormalized(0, 0)).toEqual({ ok: true });
    expect(validateNormalized(1, 1)).toEqual({ ok: true });
    expect(validateNormalized(0.5, 0.9)).toEqual({ ok: true });
  });

  it('rejects coordinates outside 0..1', () => {
    expect(validateNormalized(-0.01, 0.5).ok).toBe(false);
    expect(validateNormalized(0.5, 1.5).ok).toBe(false);
    const r = validateNormalized(2, 0.5);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/normalized 0\.\.1/);
  });

  it('names the offending axis in the reason', () => {
    const rx = validateNormalized(5, 0.5);
    const ry = validateNormalized(0.5, 5);
    expect(rx.ok).toBe(false);
    expect(ry.ok).toBe(false);
    if (!rx.ok) expect(rx.reason.startsWith('x')).toBe(true);
    if (!ry.ok) expect(ry.reason.startsWith('y')).toBe(true);
  });

  it('rejects non-finite values (pixel coords would often be these by mistake)', () => {
    expect(validateNormalized(NaN, 0.5).ok).toBe(false);
    expect(validateNormalized(0.5, Infinity).ok).toBe(false);
    expect(
      validateNormalized('100' as unknown as number, 0.5).ok,
    ).toBe(false);
  });
});

describe('isValidOrientation', () => {
  it('accepts the four serve-sim orientations', () => {
    for (const o of ROTATE_ORIENTATIONS) {
      expect(isValidOrientation(o)).toBe(true);
    }
  });

  it('rejects anything else', () => {
    expect(isValidOrientation('landscape')).toBe(false);
    expect(isValidOrientation('PORTRAIT')).toBe(false);
    expect(isValidOrientation('')).toBe(false);
    expect(isValidOrientation('portrait; rm -rf')).toBe(false);
  });
});

describe('isValidButtonName', () => {
  it('accepts lowercase hardware-button tokens', () => {
    expect(isValidButtonName('home')).toBe(true);
    expect(isValidButtonName('lock')).toBe(true);
    expect(isValidButtonName('volume-up')).toBe(true);
  });

  it('rejects flag-shaped, uppercase, empty, or too-long names', () => {
    expect(isValidButtonName('-home')).toBe(false); // can't start with a dash
    expect(isValidButtonName('--stdin')).toBe(false);
    expect(isValidButtonName('Home')).toBe(false);
    expect(isValidButtonName('')).toBe(false);
    expect(isValidButtonName('home lock')).toBe(false); // no spaces
    expect(isValidButtonName('a'.repeat(33))).toBe(false);
  });
});

describe('gestureFrame', () => {
  it('serializes a serve-sim gesture frame', () => {
    expect(gestureFrame('begin', 0.5, 0.25)).toBe(
      '{"type":"begin","x":0.5,"y":0.25}',
    );
    expect(JSON.parse(gestureFrame('end', 0, 1))).toEqual({
      type: 'end',
      x: 0,
      y: 1,
    });
  });
});

describe('axCenterNorm', () => {
  it('computes the normalized center of a frame', () => {
    const c = axCenterNorm(
      { x: 100, y: 200, width: 100, height: 40 },
      { width: 400, height: 800 },
    );
    // center pixel = (150, 220) → /(400,800)
    expect(c.x).toBeCloseTo(0.375, 5);
    expect(c.y).toBeCloseTo(0.275, 5);
  });

  it('clamps out-of-bounds frames into 0..1', () => {
    const c = axCenterNorm(
      { x: 390, y: 790, width: 100, height: 100 },
      { width: 400, height: 800 },
    );
    expect(c.x).toBe(1);
    expect(c.y).toBe(1);
    const neg = axCenterNorm(
      { x: -50, y: -50, width: 10, height: 10 },
      { width: 400, height: 800 },
    );
    expect(neg.x).toBe(0);
    expect(neg.y).toBe(0);
  });

  it('avoids divide-by-zero on a degenerate screen', () => {
    const c = axCenterNorm(
      { x: 0, y: 0, width: 0, height: 0 },
      { width: 0, height: 0 },
    );
    expect(Number.isFinite(c.x)).toBe(true);
    expect(Number.isFinite(c.y)).toBe(true);
  });
});

describe('firstSseJson', () => {
  it('returns null until a full event has arrived', () => {
    // No terminating blank line yet — still streaming.
    expect(firstSseJson('data: {"a":1}')).toBeNull();
    expect(firstSseJson(':\n\n')).toBeNull(); // comment/heartbeat only
  });

  it('parses the first complete data event, skipping heartbeats', () => {
    const buf = ':\n\ndata: {"screen":{"width":1},"elements":[]}\n\n';
    expect(firstSseJson(buf)).toEqual({
      screen: { width: 1 },
      elements: [],
    });
  });

  it('ignores a trailing partial event after a complete one', () => {
    const buf = 'data: {"n":1}\n\ndata: {"n":2'; // second event incomplete
    expect(firstSseJson(buf)).toEqual({ n: 1 });
  });

  it('skips non-JSON data lines and keeps scanning', () => {
    const buf = 'data: not-json\n\ndata: {"ok":true}\n\n';
    expect(firstSseJson(buf)).toEqual({ ok: true });
  });
});

describe('toInspectResult', () => {
  const snapshot: AxSnapshot = {
    screen: { width: 400, height: 800 },
    elements: [
      {
        id: 'e1',
        path: '0.1',
        label: 'Log in',
        value: '',
        role: 'button',
        type: 'Button',
        enabled: true,
        frame: { x: 100, y: 200, width: 200, height: 40 },
      },
    ],
  };

  it('attaches a tap-ready centerNorm to each element', () => {
    const out = toInspectResult(snapshot);
    expect(out.screen).toEqual({ width: 400, height: 800 });
    expect(out.elements).toHaveLength(1);
    const el = out.elements[0];
    expect(el.label).toBe('Log in');
    expect(el.centerNorm.x).toBeCloseTo(0.5, 5); // (100+100)/400
    expect(el.centerNorm.y).toBeCloseTo(0.275, 5); // (200+20)/800
  });

  it('omits errors when there are none, includes them when present', () => {
    expect(toInspectResult(snapshot).errors).toBeUndefined();
    const withErr = toInspectResult({
      screen: { width: 1, height: 1 },
      elements: [],
      errors: ['Accessibility unavailable on this simulator.'],
    });
    expect(withErr.errors).toEqual([
      'Accessibility unavailable on this simulator.',
    ]);
  });
});
