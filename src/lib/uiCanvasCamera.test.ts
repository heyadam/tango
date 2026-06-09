import { describe, expect, it } from 'vitest';
import {
  FIT_MAX_ZOOM,
  MAX_ZOOM,
  MIN_ZOOM,
  type Camera,
  clampZoom,
  fitCamera,
  normalizeWheelDelta,
  panBy,
  wheelZoomFactor,
  zoomAtPoint,
} from './uiCanvasCamera';

const cam = (x = 0, y = 0, zoom = 1): Camera => ({ x, y, zoom });

// world → viewport for a given camera; the invariant zoomAtPoint preserves.
const toViewport = (c: Camera, wx: number, wy: number) => ({
  x: wx * c.zoom + c.x,
  y: wy * c.zoom + c.y,
});

describe('clampZoom', () => {
  it('passes through in-range values', () => {
    expect(clampZoom(1)).toBe(1);
    expect(clampZoom(0.5)).toBe(0.5);
  });

  it('clamps at both ends', () => {
    expect(clampZoom(0.001)).toBe(MIN_ZOOM);
    expect(clampZoom(100)).toBe(MAX_ZOOM);
  });

  it('recovers from non-finite input', () => {
    expect(clampZoom(NaN)).toBe(1);
    expect(clampZoom(Infinity)).toBe(1);
  });
});

describe('panBy', () => {
  it('offsets translation and preserves zoom', () => {
    expect(panBy(cam(10, 20, 2), -5, 15)).toEqual({ x: 5, y: 35, zoom: 2 });
  });
});

describe('zoomAtPoint', () => {
  it('keeps the world point under the cursor fixed', () => {
    const before = cam(40, -30, 0.8);
    const point = { x: 200, y: 150 };
    // World point currently under the cursor.
    const wx = (point.x - before.x) / before.zoom;
    const wy = (point.y - before.y) / before.zoom;
    const after = zoomAtPoint(before, point, 2);
    expect(after.zoom).toBe(2);
    const mapped = toViewport(after, wx, wy);
    expect(mapped.x).toBeCloseTo(point.x);
    expect(mapped.y).toBeCloseTo(point.y);
  });

  it('clamps the requested zoom', () => {
    expect(zoomAtPoint(cam(), { x: 0, y: 0 }, 100).zoom).toBe(MAX_ZOOM);
    expect(zoomAtPoint(cam(), { x: 0, y: 0 }, 0).zoom).toBe(MIN_ZOOM);
  });

  it('is a no-op when zoom is unchanged', () => {
    const before = cam(12, 34, 1.5);
    expect(zoomAtPoint(before, { x: 99, y: 7 }, 1.5)).toEqual(before);
  });
});

describe('fitCamera', () => {
  it('centers content smaller than the viewport at 100%', () => {
    const out = fitCamera({ w: 400, h: 300 }, { w: 1000, h: 800 });
    expect(out.zoom).toBe(FIT_MAX_ZOOM);
    expect(out.x).toBe(300);
    expect(out.y).toBe(250);
  });

  it('scales content larger than the viewport down to fit, centered', () => {
    const out = fitCamera({ w: 2000, h: 500 }, { w: 1000, h: 800 });
    expect(out.zoom).toBe(0.5);
    expect(out.x).toBe(0);
    expect(out.y).toBe((800 - 500 * 0.5) / 2);
  });

  it('floors at MIN_ZOOM for huge content', () => {
    const out = fitCamera({ w: 100000, h: 100 }, { w: 1000, h: 800 });
    expect(out.zoom).toBe(MIN_ZOOM);
  });

  it('returns the identity camera for degenerate sizes', () => {
    expect(fitCamera({ w: 0, h: 100 }, { w: 1000, h: 800 })).toEqual(cam());
    expect(fitCamera({ w: 100, h: 100 }, { w: 0, h: 0 })).toEqual(cam());
  });
});

describe('normalizeWheelDelta', () => {
  it('passes pixel deltas through (mode 0)', () => {
    expect(normalizeWheelDelta(3, -7, 0)).toEqual({ dx: 3, dy: -7 });
  });

  it('scales line deltas (mode 1)', () => {
    expect(normalizeWheelDelta(1, -2, 1)).toEqual({ dx: 16, dy: -32 });
  });

  it('scales page deltas (mode 2)', () => {
    expect(normalizeWheelDelta(0, 1, 2)).toEqual({ dx: 0, dy: 800 });
  });
});

describe('wheelZoomFactor', () => {
  it('zooms in on negative delta, out on positive', () => {
    expect(wheelZoomFactor(-10)).toBeGreaterThan(1);
    expect(wheelZoomFactor(10)).toBeLessThan(1);
    expect(wheelZoomFactor(0)).toBe(1);
  });

  it('clamps runaway single-event deltas', () => {
    expect(wheelZoomFactor(-5000)).toBe(wheelZoomFactor(-80));
    expect(wheelZoomFactor(5000)).toBe(wheelZoomFactor(80));
  });
});
