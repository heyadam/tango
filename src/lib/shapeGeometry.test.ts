import { describe, expect, it } from 'vitest';
import {
  arrowHeadPoints,
  linePoints,
  pickLineEnd,
  pickStarPointCount,
  starPoints,
  trianglePoints,
} from './shapeGeometry';

describe('pickLineEnd', () => {
  it('accepts all eight compass values', () => {
    for (const end of ['n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw'] as const) {
      expect(pickLineEnd(end)).toBe(end);
    }
  });

  it('defaults junk to e', () => {
    expect(pickLineEnd(undefined)).toBe('e');
    expect(pickLineEnd('northwest')).toBe('e');
    expect(pickLineEnd(42)).toBe('e');
  });
});

describe('linePoints', () => {
  it('centers axis directions on the box midline', () => {
    expect(linePoints(100, 10, 'e')).toEqual([
      { x: 0, y: 5 },
      { x: 100, y: 5 },
    ]);
    expect(linePoints(10, 100, 's')).toEqual([
      { x: 5, y: 0 },
      { x: 5, y: 100 },
    ]);
  });

  it('reversed axis directions swap start and end', () => {
    const [s1, e1] = linePoints(100, 10, 'e');
    const [s2, e2] = linePoints(100, 10, 'w');
    expect(s2).toEqual(e1);
    expect(e2).toEqual(s1);
  });

  it('diagonals run corner to corner with the end at the named corner', () => {
    expect(linePoints(80, 60, 'se')).toEqual([
      { x: 0, y: 0 },
      { x: 80, y: 60 },
    ]);
    expect(linePoints(80, 60, 'ne')).toEqual([
      { x: 0, y: 60 },
      { x: 80, y: 0 },
    ]);
  });
});

describe('arrowHeadPoints', () => {
  it('puts the tip at the line end', () => {
    const line = linePoints(100, 10, 'e');
    const [, tip] = line;
    const head = arrowHeadPoints(line, 2);
    expect(head[1]).toEqual(tip);
  });

  it('wings sit behind the tip, symmetric about the line axis', () => {
    const head = arrowHeadPoints(
      [
        { x: 0, y: 5 },
        { x: 100, y: 5 },
      ],
      2,
    );
    const [w1, tip, w2] = head;
    expect(w1.x).toBeLessThan(tip.x);
    expect(w2.x).toBeLessThan(tip.x);
    expect(w1.x).toBeCloseTo(w2.x, 5);
    // Symmetric across y = 5.
    expect(w1.y + w2.y).toBeCloseTo(10, 5);
    expect(w1.y).not.toBeCloseTo(w2.y, 5);
  });

  it('scales wing length with stroke width, floored at 8', () => {
    const line: [{ x: number; y: number }, { x: number; y: number }] = [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
    ];
    const thin = arrowHeadPoints(line, 1);
    const thick = arrowHeadPoints(line, 4);
    const wingLen = (h: typeof thin) => Math.hypot(h[1].x - h[0].x, h[1].y - h[0].y);
    expect(wingLen(thin)).toBeCloseTo(8, 1);
    expect(wingLen(thick)).toBeCloseTo(16, 1);
  });

  it('survives a degenerate zero-length line', () => {
    const head = arrowHeadPoints(
      [
        { x: 5, y: 5 },
        { x: 5, y: 5 },
      ],
      2,
    );
    expect(head[1]).toEqual({ x: 5, y: 5 });
    for (const p of head) {
      expect(Number.isFinite(p.x)).toBe(true);
      expect(Number.isFinite(p.y)).toBe(true);
    }
  });
});

describe('trianglePoints', () => {
  it('apex top-center, base corners at the bottom', () => {
    expect(trianglePoints(100, 80)).toEqual([
      { x: 50, y: 0 },
      { x: 100, y: 80 },
      { x: 0, y: 80 },
    ]);
  });
});

describe('pickStarPointCount', () => {
  it('defaults to 5 and clamps to 3–12', () => {
    expect(pickStarPointCount(undefined)).toBe(5);
    expect(pickStarPointCount('7')).toBe(5);
    expect(pickStarPointCount(7)).toBe(7);
    expect(pickStarPointCount(2)).toBe(3);
    expect(pickStarPointCount(99)).toBe(12);
  });
});

describe('starPoints', () => {
  it('emits 2n points, first at 12 o\'clock', () => {
    const pts = starPoints(100, 100, 5);
    expect(pts).toHaveLength(10);
    expect(pts[0]).toEqual({ x: 50, y: 0 });
  });

  it('alternates outer and inner radius', () => {
    const pts = starPoints(100, 100, 5);
    const r = (p: { x: number; y: number }) => Math.hypot(p.x - 50, p.y - 50);
    for (let i = 0; i < pts.length; i += 1) {
      expect(r(pts[i])).toBeCloseTo(i % 2 === 0 ? 50 : 20, 1);
    }
  });

  it('scales to a non-square box', () => {
    const pts = starPoints(200, 100, 4);
    // The 3 o'clock outer point (index 2 of 8 for n=4) lands at the box edge.
    expect(pts[2]).toEqual({ x: 200, y: 50 });
    for (const p of pts) {
      expect(p.x).toBeGreaterThanOrEqual(0);
      expect(p.x).toBeLessThanOrEqual(200);
      expect(p.y).toBeGreaterThanOrEqual(0);
      expect(p.y).toBeLessThanOrEqual(100);
    }
  });
});
