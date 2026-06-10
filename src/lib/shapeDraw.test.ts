import { describe, expect, it } from 'vitest';
import { dropAtPoint, shapeFromDrag } from './shapeDraw';

const FRAME = { w: 390, h: 844 };

describe('shapeFromDrag — box shapes', () => {
  it('normalizes a down-right drag', () => {
    const r = shapeFromDrag('rect', { x: 10, y: 20 }, { x: 110, y: 80 }, { shift: false, frame: FRAME });
    expect(r).toEqual({ x: 10, y: 20, width: 100, height: 60 });
  });

  it('normalizes an up-left drag (negative deltas)', () => {
    const r = shapeFromDrag('ellipse', { x: 110, y: 80 }, { x: 10, y: 20 }, { shift: false, frame: FRAME });
    expect(r).toEqual({ x: 10, y: 20, width: 100, height: 60 });
  });

  it('shift constrains to a square on the larger axis', () => {
    const r = shapeFromDrag('rect', { x: 0, y: 0 }, { x: 100, y: 40 }, { shift: true, frame: FRAME });
    expect(r).toEqual({ x: 0, y: 0, width: 100, height: 100 });
  });

  it('returns null for a click-sized gesture', () => {
    expect(
      shapeFromDrag('rect', { x: 50, y: 50 }, { x: 52, y: 53 }, { shift: false, frame: FRAME }),
    ).toBeNull();
  });

  it('enforces a minimum size on skinny drags', () => {
    const r = shapeFromDrag('rect', { x: 10, y: 10 }, { x: 100, y: 12 }, { shift: false, frame: FRAME });
    expect(r!.height).toBe(8);
  });

  it('clamps into the frame', () => {
    const r = shapeFromDrag('rect', { x: 380, y: 830 }, { x: 500, y: 900 }, { shift: false, frame: FRAME });
    expect(r!.x + r!.width).toBeLessThanOrEqual(FRAME.w);
    expect(r!.y + r!.height).toBeLessThanOrEqual(FRAME.h);
  });
});

describe('shapeFromDrag — lines and arrows', () => {
  it('a flat drag snaps to a horizontal thin box pointing e', () => {
    const r = shapeFromDrag('line', { x: 10, y: 100 }, { x: 200, y: 103 }, { shift: false, frame: FRAME });
    expect(r).toMatchObject({ x: 10, width: 190, height: 8, end: 'e' });
    // Midline of the thin box sits on the drag's average y: 101.5 - 4 → 98.
    expect(r!.y).toBe(98);
  });

  it('a right-to-left flat drag points w', () => {
    const r = shapeFromDrag('arrow', { x: 200, y: 100 }, { x: 10, y: 100 }, { shift: false, frame: FRAME });
    expect(r).toMatchObject({ x: 10, width: 190, end: 'w' });
  });

  it('a tall drag snaps vertical, pointing s or n', () => {
    const down = shapeFromDrag('line', { x: 100, y: 10 }, { x: 102, y: 200 }, { shift: false, frame: FRAME });
    expect(down).toMatchObject({ width: 8, height: 190, end: 's' });
    const up = shapeFromDrag('line', { x: 100, y: 200 }, { x: 102, y: 10 }, { shift: false, frame: FRAME });
    expect(up).toMatchObject({ end: 'n' });
  });

  it('diagonal drags map quadrants to compass corners', () => {
    const se = shapeFromDrag('line', { x: 10, y: 10 }, { x: 100, y: 80 }, { shift: false, frame: FRAME });
    expect(se).toMatchObject({ x: 10, y: 10, width: 90, height: 70, end: 'se' });
    const ne = shapeFromDrag('line', { x: 10, y: 80 }, { x: 100, y: 10 }, { shift: false, frame: FRAME });
    expect(ne).toMatchObject({ x: 10, y: 10, end: 'ne' });
    const sw = shapeFromDrag('line', { x: 100, y: 10 }, { x: 10, y: 80 }, { shift: false, frame: FRAME });
    expect(sw).toMatchObject({ end: 'sw' });
    const nw = shapeFromDrag('line', { x: 100, y: 80 }, { x: 10, y: 10 }, { shift: false, frame: FRAME });
    expect(nw).toMatchObject({ end: 'nw' });
  });

  it('shift snaps a near-flat drag to exactly horizontal', () => {
    const r = shapeFromDrag('line', { x: 10, y: 100 }, { x: 200, y: 130 }, { shift: true, frame: FRAME });
    expect(r).toMatchObject({ height: 8, end: 'e' });
  });

  it('shift snaps a near-diagonal drag to 45°', () => {
    const r = shapeFromDrag('line', { x: 10, y: 10 }, { x: 100, y: 70 }, { shift: true, frame: FRAME });
    expect(r).toMatchObject({ width: 90, height: 90, end: 'se' });
  });

  it('returns null for a sub-minimum line', () => {
    expect(
      shapeFromDrag('line', { x: 10, y: 10 }, { x: 15, y: 25 }, { shift: false, frame: FRAME }),
    ).toBeDefined();
    expect(
      shapeFromDrag('line', { x: 10, y: 10 }, { x: 13, y: 14 }, { shift: false, frame: FRAME }),
    ).toBeNull();
  });
});

describe('dropAtPoint', () => {
  it('centers the default size on the click', () => {
    expect(dropAtPoint({ width: 100, height: 60 }, { x: 200, y: 200 }, FRAME)).toEqual({
      x: 150,
      y: 170,
      width: 100,
      height: 60,
    });
  });

  it('clamps near edges', () => {
    const r = dropAtPoint({ width: 100, height: 60 }, { x: 5, y: 840 }, FRAME);
    expect(r.x).toBe(0);
    expect(r.y + r.height).toBeLessThanOrEqual(FRAME.h);
  });
});
