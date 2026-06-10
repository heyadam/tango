// Pure drag→node-geometry math for the canvas draw tools. Start/end points
// arrive in frame-local pixel coords (the canvas converts from client space
// through the camera); the result is ready to merge into a fresh UINode.
// Kept out of UIMockCanvas so the fiddly cases (negative drags, shift
// constraints, axis snapping for lines, frame clamping) are unit-testable.

import type { LineEnd, UINodeType } from './uiMockProtocol';

export type DrawPoint = { x: number; y: number };

export type DrawResult = {
  x: number;
  y: number;
  width: number;
  height: number;
  // For line/arrow: the compass `end` prop derived from the drag direction.
  end?: LineEnd;
};

// Drags shorter than this (in frame px) are treated as a click — the caller
// drops a default-sized node instead.
export const CLICK_THRESHOLD = 4;

// Nothing smaller than this on either axis survives a draw.
const MIN_SIZE = 8;

// Lines flatter/narrower than this snap to the axis and get a thin box.
const AXIS_SNAP = 8;

const LINE_BOX_THICKNESS = 8;

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), Math.max(lo, hi));
}

// Clamp a rect into the frame, shrinking it if it's bigger than the frame.
function clampToFrame(
  r: { x: number; y: number; width: number; height: number },
  frame: { w: number; h: number },
): { x: number; y: number; width: number; height: number } {
  const width = Math.min(r.width, frame.w);
  const height = Math.min(r.height, frame.h);
  return {
    x: Math.round(clamp(r.x, 0, frame.w - width)),
    y: Math.round(clamp(r.y, 0, frame.h - height)),
    width: Math.round(width),
    height: Math.round(height),
  };
}

export function isLineTool(type: UINodeType): boolean {
  return type === 'line' || type === 'arrow';
}

// Box-drawn shapes: rect/ellipse/triangle/star (and any future box shape).
function boxFromDrag(
  start: DrawPoint,
  end: DrawPoint,
  shift: boolean,
  frame: { w: number; h: number },
): DrawResult {
  let w = Math.abs(end.x - start.x);
  let h = Math.abs(end.y - start.y);
  if (shift) {
    const side = Math.max(w, h);
    w = side;
    h = side;
  }
  w = Math.max(MIN_SIZE, w);
  h = Math.max(MIN_SIZE, h);
  const x = end.x >= start.x ? start.x : start.x - w;
  const y = end.y >= start.y ? start.y : start.y - h;
  return clampToFrame({ x, y, width: w, height: h }, frame);
}

function lineFromDrag(
  start: DrawPoint,
  end: DrawPoint,
  shift: boolean,
  frame: { w: number; h: number },
): DrawResult | null {
  let dx = end.x - start.x;
  let dy = end.y - start.y;
  if (Math.hypot(dx, dy) < MIN_SIZE) return null;

  if (shift) {
    // Snap to horizontal / vertical / 45° diagonal, whichever is closest.
    const ax = Math.abs(dx);
    const ay = Math.abs(dy);
    if (ay < ax / 2) {
      dy = 0;
    } else if (ax < ay / 2) {
      dx = 0;
    } else {
      const side = Math.max(ax, ay);
      dx = Math.sign(dx) * side;
      dy = Math.sign(dy) * side;
    }
  }

  // Axis-snapped (or genuinely flat) drags become a thin box with the line
  // on its midline; diagonals fill the drag's bounding box corner-to-corner.
  if (Math.abs(dy) < AXIS_SNAP) {
    const w = Math.max(MIN_SIZE, Math.abs(dx));
    const midY = start.y + dy / 2;
    const rect = clampToFrame(
      {
        x: dx >= 0 ? start.x : start.x - w,
        y: midY - LINE_BOX_THICKNESS / 2,
        width: w,
        height: LINE_BOX_THICKNESS,
      },
      frame,
    );
    return { ...rect, end: dx >= 0 ? 'e' : 'w' };
  }
  if (Math.abs(dx) < AXIS_SNAP) {
    const h = Math.max(MIN_SIZE, Math.abs(dy));
    const midX = start.x + dx / 2;
    const rect = clampToFrame(
      {
        x: midX - LINE_BOX_THICKNESS / 2,
        y: dy >= 0 ? start.y : start.y - h,
        width: LINE_BOX_THICKNESS,
        height: h,
      },
      frame,
    );
    return { ...rect, end: dy >= 0 ? 's' : 'n' };
  }

  const w = Math.abs(dx);
  const h = Math.abs(dy);
  const rect = clampToFrame(
    {
      x: dx >= 0 ? start.x : start.x - w,
      y: dy >= 0 ? start.y : start.y - h,
      width: w,
      height: h,
    },
    frame,
  );
  const lineEnd: LineEnd =
    dx >= 0 ? (dy >= 0 ? 'se' : 'ne') : dy >= 0 ? 'sw' : 'nw';
  return { ...rect, end: lineEnd };
}

// The draw-tool commit. Returns null when the gesture should be treated as a
// click (too small to be a meaningful drag) — drop a default-sized node then.
export function shapeFromDrag(
  type: UINodeType,
  start: DrawPoint,
  end: DrawPoint,
  opts: { shift: boolean; frame: { w: number; h: number } },
): DrawResult | null {
  if (
    Math.abs(end.x - start.x) < CLICK_THRESHOLD &&
    Math.abs(end.y - start.y) < CLICK_THRESHOLD
  ) {
    return null;
  }
  if (isLineTool(type)) {
    return lineFromDrag(start, end, opts.shift, opts.frame);
  }
  return boxFromDrag(start, end, opts.shift, opts.frame);
}

// Click-drop placement: default size centered on the click, clamped in-frame.
export function dropAtPoint(
  size: { width: number; height: number },
  point: DrawPoint,
  frame: { w: number; h: number },
): { x: number; y: number; width: number; height: number } {
  return clampToFrame(
    {
      x: point.x - size.width / 2,
      y: point.y - size.height / 2,
      width: size.width,
      height: size.height,
    },
    frame,
  );
}
