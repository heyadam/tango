// Pixel-space point math for the vector shape node types (line/arrow/
// triangle/star). This is the ONLY place shape geometry is computed: the
// resolver (uiResolve) calls these with the node's width/height and puts the
// resulting points on the ResolvedNode, so the web canvas (SVG), the SwiftUI
// codegen (Path), and the preview host all plot the same literal coordinates.
// Keep renderers dumb — never re-derive geometry downstream.

import type { LineEnd } from './uiMockProtocol';

export type Point = { x: number; y: number };

// Two decimals: enough for sub-pixel fidelity, stable for golden files.
function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function pt(x: number, y: number): Point {
  return { x: round2(x), y: round2(y) };
}

export function pickLineEnd(raw: unknown): LineEnd {
  switch (raw) {
    case 'n':
    case 'ne':
    case 'e':
    case 'se':
    case 's':
    case 'sw':
    case 'w':
    case 'nw':
      return raw;
    default:
      return 'e';
  }
}

// Start → end segment inside a w×h box. Diagonals run corner-to-corner; the
// axis directions center on the box midline so a thin box reads as a straight
// rule. The end point is where the arrowhead goes.
export function linePoints(w: number, h: number, end: LineEnd): [Point, Point] {
  switch (end) {
    case 'e':
      return [pt(0, h / 2), pt(w, h / 2)];
    case 'w':
      return [pt(w, h / 2), pt(0, h / 2)];
    case 's':
      return [pt(w / 2, 0), pt(w / 2, h)];
    case 'n':
      return [pt(w / 2, h), pt(w / 2, 0)];
    case 'se':
      return [pt(0, 0), pt(w, h)];
    case 'nw':
      return [pt(w, h), pt(0, 0)];
    case 'ne':
      return [pt(0, h), pt(w, 0)];
    case 'sw':
      return [pt(w, 0), pt(0, h)];
  }
}

// Open V at the line's end point: wing → tip → wing. Renderers stroke it with
// the same width/cap as the line itself (never fill it). Wing length scales
// with stroke width so heavier lines get proportionally bigger heads.
export function arrowHeadPoints(
  line: [Point, Point],
  strokeWidth: number,
): [Point, Point, Point] {
  const [start, tip] = line;
  const dx = tip.x - start.x;
  const dy = tip.y - start.y;
  const len = Math.hypot(dx, dy);
  // Degenerate (zero-length) segment: point the head right.
  const ux = len > 0 ? dx / len : 1;
  const uy = len > 0 ? dy / len : 0;
  const wing = Math.max(8, strokeWidth * 4);
  const spread = (28 * Math.PI) / 180;
  const cos = Math.cos(spread);
  const sin = Math.sin(spread);
  // Rotate the reversed direction ±spread, scale by wing length.
  const bx = -ux;
  const by = -uy;
  const w1 = pt(tip.x + wing * (bx * cos - by * sin), tip.y + wing * (bx * sin + by * cos));
  const w2 = pt(tip.x + wing * (bx * cos + by * sin), tip.y + wing * (-bx * sin + by * cos));
  return [w1, pt(tip.x, tip.y), w2];
}

// Isoceles triangle, apex top-center.
export function trianglePoints(w: number, h: number): Point[] {
  return [pt(w / 2, 0), pt(w, h), pt(0, h)];
}

export function pickStarPointCount(raw: unknown): number {
  const n = typeof raw === 'number' ? Math.round(raw) : NaN;
  if (!Number.isFinite(n)) return 5;
  return Math.min(12, Math.max(3, n));
}

// n-pointed star inscribed in the w×h box, first point at 12 o'clock.
// Inner radius fixed at 40% of outer — close to Figma's default ratio.
const STAR_INNER_RATIO = 0.4;

export function starPoints(w: number, h: number, points: number): Point[] {
  const cx = w / 2;
  const cy = h / 2;
  const out: Point[] = [];
  for (let i = 0; i < points * 2; i += 1) {
    const angle = -Math.PI / 2 + (i * Math.PI) / points;
    const ratio = i % 2 === 0 ? 1 : STAR_INNER_RATIO;
    out.push(
      pt(cx + (w / 2) * ratio * Math.cos(angle), cy + (h / 2) * ratio * Math.sin(angle)),
    );
  }
  return out;
}
