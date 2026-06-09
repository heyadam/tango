// Color math + the tango theme palette as concrete RGBA values.
//
// The design canvas styles nodes with theme-token Tailwind (`bg-primary`,
// `text-muted-foreground`) whose actual colors live as OKLCH custom
// properties in src/app/globals.css. The SwiftUI codegen and the preview-host
// wire protocol both need *concrete* colors — Swift never parses CSS — so this
// module converts OKLCH → sRGB and pins the palette in TS.
//
// LOCKSTEP: `TANGO_THEME` mirrors the `:root` (light) palette in
// src/app/globals.css. The mock always renders the light theme (no `.dark`
// class is ever set on <html>), so one table suffices. If globals.css
// changes, update the literals here.

export type RGBA = {
  r: number; // 0–255
  g: number; // 0–255
  b: number; // 0–255
  a: number; // 0–1
};

export function rgba(r: number, g: number, b: number, a = 1): RGBA {
  return { r, g, b, a };
}

export function withAlpha(c: RGBA, a: number): RGBA {
  return { ...c, a };
}

// ── OKLCH → sRGB ──────────────────────────────────────────────────────────
// Standard pipeline (Björn Ottosson's OKLab): OKLCH → OKLab → LMS → linear
// sRGB → gamma-encoded sRGB. Out-of-gamut channels are clamped.

function gammaEncode(c: number): number {
  const v = c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
  return Math.min(1, Math.max(0, v));
}

export function oklchToRgba(
  l: number,
  c: number,
  h: number,
  alpha = 1,
): RGBA {
  const hRad = (h * Math.PI) / 180;
  const labA = c * Math.cos(hRad);
  const labB = c * Math.sin(hRad);

  const l_ = l + 0.3963377774 * labA + 0.2158037573 * labB;
  const m_ = l - 0.1055613458 * labA - 0.0638541728 * labB;
  const s_ = l - 0.0894841775 * labA - 1.291485548 * labB;

  const lc = l_ ** 3;
  const mc = m_ ** 3;
  const sc = s_ ** 3;

  const rLin = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc;
  const gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc;
  const bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.707614701 * sc;

  return {
    r: Math.round(gammaEncode(rLin) * 255),
    g: Math.round(gammaEncode(gLin) * 255),
    b: Math.round(gammaEncode(bLin) * 255),
    a: alpha,
  };
}

// ── tango theme palette ───────────────────────────────────────────────────

export type ThemeToken =
  | 'background'
  | 'foreground'
  | 'card'
  | 'card-foreground'
  | 'popover'
  | 'popover-foreground'
  | 'primary'
  | 'primary-foreground'
  | 'secondary'
  | 'secondary-foreground'
  | 'muted'
  | 'muted-foreground'
  | 'accent'
  | 'accent-foreground'
  | 'destructive'
  | 'destructive-foreground'
  | 'warning'
  | 'warning-foreground'
  | 'border'
  | 'input'
  | 'ring';

// Literals copied from globals.css `:root` — see LOCKSTEP note above.
export const TANGO_THEME: Record<ThemeToken, RGBA> = {
  background: oklchToRgba(0.95, 0.02, 85),
  foreground: oklchToRgba(0.2, 0.07, 270),
  card: oklchToRgba(0.99, 0.005, 85),
  'card-foreground': oklchToRgba(0.2, 0.07, 270),
  popover: oklchToRgba(0.99, 0.005, 85),
  'popover-foreground': oklchToRgba(0.2, 0.07, 270),
  primary: oklchToRgba(0.55, 0.2, 280),
  'primary-foreground': oklchToRgba(0.99, 0.005, 85),
  secondary: oklchToRgba(0.81, 0.08, 170),
  'secondary-foreground': oklchToRgba(0.2, 0.07, 270),
  muted: oklchToRgba(0.93, 0.02, 85),
  'muted-foreground': oklchToRgba(0.45, 0.05, 270),
  accent: oklchToRgba(0.93, 0.03, 60),
  'accent-foreground': oklchToRgba(0.2, 0.07, 270),
  destructive: oklchToRgba(0.66, 0.21, 0),
  'destructive-foreground': oklchToRgba(0.99, 0.005, 85),
  warning: oklchToRgba(0.74, 0.16, 60),
  'warning-foreground': oklchToRgba(0.3, 0.1, 60),
  border: oklchToRgba(0.88, 0.02, 270),
  input: oklchToRgba(0.88, 0.02, 270),
  ring: oklchToRgba(0.55, 0.2, 280),
};

export function isThemeToken(s: string): s is ThemeToken {
  return s in TANGO_THEME;
}

// ── CSS color parsing (the subset agents actually emit) ───────────────────

const NAMED_COLORS: Record<string, RGBA> = {
  transparent: rgba(0, 0, 0, 0),
  white: rgba(255, 255, 255),
  black: rgba(0, 0, 0),
  red: rgba(255, 0, 0),
  green: rgba(0, 128, 0),
  blue: rgba(0, 0, 255),
  yellow: rgba(255, 255, 0),
  orange: rgba(255, 165, 0),
  purple: rgba(128, 0, 128),
  pink: rgba(255, 192, 203),
  teal: rgba(0, 128, 128),
  navy: rgba(0, 0, 128),
  gray: rgba(128, 128, 128),
  grey: rgba(128, 128, 128),
  silver: rgba(192, 192, 192),
};

function parseHex(hex: string): RGBA | null {
  const h = hex.slice(1);
  if (!/^[0-9a-fA-F]+$/.test(h)) return null;
  if (h.length === 3 || h.length === 4) {
    const r = parseInt(h[0] + h[0], 16);
    const g = parseInt(h[1] + h[1], 16);
    const b = parseInt(h[2] + h[2], 16);
    const a = h.length === 4 ? parseInt(h[3] + h[3], 16) / 255 : 1;
    return { r, g, b, a };
  }
  if (h.length === 6 || h.length === 8) {
    const r = parseInt(h.slice(0, 2), 16);
    const g = parseInt(h.slice(2, 4), 16);
    const b = parseInt(h.slice(4, 6), 16);
    const a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    return { r, g, b, a };
  }
  return null;
}

function parseRgbFn(body: string): RGBA | null {
  // Accept comma and space syntax: `255, 0, 0`, `255 0 0 / 0.5`, `255,0,0,0.5`.
  const parts = body
    .replace(/\//g, ' ')
    .split(/[\s,]+/)
    .filter(Boolean);
  if (parts.length < 3 || parts.length > 4) return null;
  const channel = (s: string): number | null => {
    if (s.endsWith('%')) {
      const pct = Number(s.slice(0, -1));
      return Number.isFinite(pct) ? Math.round((pct / 100) * 255) : null;
    }
    const n = Number(s);
    return Number.isFinite(n) ? Math.round(n) : null;
  };
  const r = channel(parts[0]);
  const g = channel(parts[1]);
  const b = channel(parts[2]);
  if (r == null || g == null || b == null) return null;
  let a = 1;
  if (parts.length === 4) {
    const raw = parts[3];
    const n = raw.endsWith('%') ? Number(raw.slice(0, -1)) / 100 : Number(raw);
    if (!Number.isFinite(n)) return null;
    a = Math.min(1, Math.max(0, n));
  }
  const clamp = (v: number) => Math.min(255, Math.max(0, v));
  return { r: clamp(r), g: clamp(g), b: clamp(b), a };
}

function parseOklchFn(body: string): RGBA | null {
  const parts = body
    .replace(/\//g, ' ')
    .split(/[\s,]+/)
    .filter(Boolean);
  if (parts.length < 3 || parts.length > 4) return null;
  const num = (s: string, pct100 = false): number | null => {
    if (s.endsWith('%')) {
      const p = Number(s.slice(0, -1));
      return Number.isFinite(p) ? p / 100 : null;
    }
    const n = Number(s);
    if (!Number.isFinite(n)) return null;
    return pct100 ? n : n;
  };
  const l = num(parts[0]);
  const c = num(parts[1]);
  const h = parts[2] === 'none' ? 0 : Number(parts[2].replace(/deg$/, ''));
  if (l == null || c == null || !Number.isFinite(h)) return null;
  let a = 1;
  if (parts.length === 4) {
    const v = num(parts[3]);
    if (v == null) return null;
    a = Math.min(1, Math.max(0, v));
  }
  return oklchToRgba(l, c, h, a);
}

export function parseCssColor(value: string): RGBA | null {
  const v = value.trim();
  if (v.startsWith('#')) return parseHex(v);
  const fn = /^(rgba?|oklch)\(([^)]*)\)$/i.exec(v);
  if (fn) {
    const name = fn[1].toLowerCase();
    if (name === 'rgb' || name === 'rgba') return parseRgbFn(fn[2]);
    return parseOklchFn(fn[2]);
  }
  const named = NAMED_COLORS[v.toLowerCase()];
  return named ?? null;
}

// ── linear-gradient parsing (best effort) ─────────────────────────────────

export type Gradient = {
  angleDeg: number; // CSS convention: 0 = to top, 90 = to right
  stops: Array<{ color: RGBA; at: number }>; // at: 0–1
};

// Split on top-level commas only (rgb(1,2,3) contains commas).
function splitTopLevel(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if (ch === '(') depth += 1;
    else if (ch === ')') depth -= 1;
    if (ch === ',' && depth === 0) {
      out.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

const SIDE_ANGLES: Record<string, number> = {
  'to top': 0,
  'to top right': 45,
  'to right': 90,
  'to bottom right': 135,
  'to bottom': 180,
  'to bottom left': 225,
  'to left': 270,
  'to top left': 315,
};

export function parseLinearGradient(value: string): Gradient | null {
  const m = /^linear-gradient\(([\s\S]*)\)$/i.exec(value.trim());
  if (!m) return null;
  const parts = splitTopLevel(m[1]);
  if (parts.length === 0) return null;

  let angleDeg = 180; // CSS default: to bottom
  let stopParts = parts;
  const first = parts[0].toLowerCase();
  const angleMatch = /^(-?\d+(?:\.\d+)?)deg$/.exec(first);
  if (angleMatch) {
    angleDeg = Number(angleMatch[1]);
    stopParts = parts.slice(1);
  } else if (first in SIDE_ANGLES) {
    angleDeg = SIDE_ANGLES[first];
    stopParts = parts.slice(1);
  }

  const stops: Array<{ color: RGBA; at: number | null }> = [];
  for (const part of stopParts) {
    // `<color> [<pos>%]` — color may contain spaces inside fn parens only.
    const posMatch = /\s+(-?\d+(?:\.\d+)?)%$/.exec(part);
    const colorStr = posMatch ? part.slice(0, posMatch.index) : part;
    const color = parseCssColor(colorStr.trim());
    if (!color) return null;
    stops.push({
      color,
      at: posMatch ? Math.min(1, Math.max(0, Number(posMatch[1]) / 100)) : null,
    });
  }
  if (stops.length < 2) return null;

  // Fill missing positions: endpoints default to 0/1, interior stops spread
  // evenly between their nearest positioned neighbors (simplified: even
  // spread across the whole run — fine for the gradients agents emit).
  const n = stops.length;
  const resolved = stops.map((s, i) => ({
    color: s.color,
    at: s.at ?? i / (n - 1),
  }));
  return { angleDeg, stops: resolved };
}
