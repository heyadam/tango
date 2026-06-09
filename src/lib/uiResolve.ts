// Resolve a UISpec into concrete, render-ready values: theme-token Tailwind
// classes and inline CSS flattened into RGBA colors, pixel sizes, and simple
// enums. Consumed by BOTH the SwiftUI codegen (specToSwiftUI) and the
// preview-host wire protocol (previewBridge → Swift renderer), so all CSS/
// Tailwind knowledge lives here and Swift stays dumb.
//
// Layering order per node (later wins per-property):
//   1. per-kind / per-variant baseline — mirrors what UIMockNode.tsx renders
//   2. the Tailwind subset parsed from `className` (unknown classes ignored;
//      layout classes ignored by policy — coords win)
//   3. inline `style` (the off-theme color channel)

import type { UINode, UIScreen, UISpec } from './uiMockProtocol';
import {
  type Gradient,
  type RGBA,
  TANGO_THEME,
  isThemeToken,
  parseCssColor,
  parseLinearGradient,
  rgba,
  withAlpha,
} from './themeColors';
import { lucideToSfSymbol } from './lucideToSfSymbol';

export type ResolvedStyle = {
  backgroundColor?: RGBA;
  gradient?: Gradient;
  textColor?: RGBA;
  fontSize?: number; // px ≈ pt
  fontWeight?: 100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900;
  fontFamily?: 'sans' | 'serif' | 'mono';
  italic?: boolean;
  textAlign?: 'leading' | 'center' | 'trailing';
  cornerRadius?: number;
  borderWidth?: number;
  borderColor?: RGBA;
  borderDashed?: boolean;
  opacity?: number; // 0–1
  padding?: { top: number; right: number; bottom: number; left: number };
  shadow?: { radius: number; y: number; alpha: number };
};

export type ResolvedNodeKind =
  | 'box'
  | 'text'
  | 'button'
  | 'input'
  | 'textarea'
  | 'badge'
  | 'separator'
  | 'image'
  | 'icon';

export type ResolvedNode = {
  id: string;
  kind: ResolvedNodeKind;
  x: number;
  y: number;
  width: number;
  height: number;
  text?: string;
  // Input/Textarea: `text` is placeholder copy — render muted.
  isPlaceholderText?: boolean;
  sfSymbol?: string; // icon only
  imageSrc?: string; // image only; http(s) URLs only
  separatorVertical?: boolean;
  style: ResolvedStyle;
};

export type ResolvedScreen = {
  id: string;
  title: string;
  frame: { w: number; h: number };
  nodes: ResolvedNode[];
};

export type ResolvedSpec = { version: 1; screens: ResolvedScreen[] };

// ── baselines (mirror UIMockNode.tsx + ui/button.tsx + ui/badge.tsx) ──────

const T = TANGO_THEME;
const TRANSPARENT = rgba(0, 0, 0, 0);

function buttonBaseline(variant: unknown): ResolvedStyle {
  const base: ResolvedStyle = {
    cornerRadius: 8, // rounded-md in this project's @theme (10px * 0.8)
    fontSize: 14,
    fontWeight: 500,
    textAlign: 'center',
    padding: { top: 0, right: 12, bottom: 0, left: 12 }, // px-3 in the mock
    shadow: { radius: 1, y: 1, alpha: 0.05 }, // shadow-xs
  };
  switch (variant) {
    case 'secondary':
      return { ...base, backgroundColor: T.secondary, textColor: T['secondary-foreground'] };
    case 'outline':
      return { ...base, backgroundColor: T.background, textColor: T.foreground, borderWidth: 1, borderColor: T.border };
    case 'ghost':
      return { ...base, backgroundColor: TRANSPARENT, textColor: T.foreground, shadow: undefined };
    case 'destructive':
      return { ...base, backgroundColor: T.destructive, textColor: T['destructive-foreground'] };
    case 'link':
      return { ...base, backgroundColor: TRANSPARENT, textColor: T.primary, shadow: undefined };
    default:
      return { ...base, backgroundColor: T.primary, textColor: T['primary-foreground'] };
  }
}

function badgeBaseline(variant: unknown): ResolvedStyle {
  const base: ResolvedStyle = {
    cornerRadius: 9999, // rounded-full
    fontSize: 12,
    fontWeight: 500,
    textAlign: 'center',
    padding: { top: 2, right: 8, bottom: 2, left: 8 }, // px-2 py-0.5
  };
  switch (variant) {
    case 'secondary':
      return { ...base, backgroundColor: T.secondary, textColor: T['secondary-foreground'] };
    case 'destructive':
      return { ...base, backgroundColor: T.destructive, textColor: T['destructive-foreground'] };
    case 'outline':
      return { ...base, backgroundColor: TRANSPARENT, textColor: T.foreground, borderWidth: 1, borderColor: T.border };
    default:
      return { ...base, backgroundColor: T.primary, textColor: T['primary-foreground'] };
  }
}

function headingBaseline(level: unknown): ResolvedStyle {
  const l = level === 1 || level === 3 ? level : 2;
  return {
    textColor: T.foreground,
    fontFamily: 'serif',
    fontSize: l === 1 ? 30 : l === 2 ? 24 : 18, // text-3xl / 2xl / lg
    fontWeight: l === 1 ? 700 : 600,
  };
}

function baselineFor(node: UINode): ResolvedStyle {
  switch (node.type) {
    case 'div':
      return {
        backgroundColor: withAlpha(T.muted, 0.3),
        borderWidth: 1,
        borderColor: withAlpha(T.border, 0.6),
        borderDashed: true,
        cornerRadius: 8,
      };
    case 'text':
      return { textColor: T.foreground, fontSize: 14 };
    case 'heading':
      return headingBaseline(node.props?.level);
    case 'Button':
      return buttonBaseline(node.props?.variant);
    case 'Input':
      return {
        backgroundColor: TRANSPARENT,
        textColor: T['muted-foreground'],
        fontSize: 14,
        cornerRadius: 8,
        borderWidth: 1,
        borderColor: T.input,
        padding: { top: 4, right: 12, bottom: 4, left: 12 },
        shadow: { radius: 1, y: 1, alpha: 0.05 },
      };
    case 'Textarea':
      return {
        backgroundColor: TRANSPARENT,
        textColor: T['muted-foreground'],
        fontSize: 14,
        cornerRadius: 8,
        borderWidth: 1,
        borderColor: T.input,
        padding: { top: 8, right: 12, bottom: 8, left: 12 },
        shadow: { radius: 1, y: 1, alpha: 0.05 },
      };
    case 'Badge':
      return badgeBaseline(node.props?.variant);
    case 'Separator':
      return { backgroundColor: T.border };
    case 'Image': {
      const hasSrc = typeof node.props?.src === 'string' && node.props.src !== '';
      return hasSrc
        ? { cornerRadius: 8 }
        : {
            backgroundColor: withAlpha(T.muted, 0.4),
            borderWidth: 1,
            borderColor: T.border,
            borderDashed: true,
            cornerRadius: 8,
            textColor: T['muted-foreground'],
          };
    }
    case 'Icon':
      return { textColor: T.foreground };
    default:
      return {};
  }
}

// ── Tailwind subset (className overlay) ───────────────────────────────────

const TEXT_SIZES: Record<string, number> = {
  'text-xs': 12,
  'text-sm': 14,
  'text-base': 16,
  'text-lg': 18,
  'text-xl': 20,
  'text-2xl': 24,
  'text-3xl': 30,
  'text-4xl': 36,
};

const FONT_WEIGHTS: Record<string, ResolvedStyle['fontWeight']> = {
  'font-thin': 100,
  'font-extralight': 200,
  'font-light': 300,
  'font-normal': 400,
  'font-medium': 500,
  'font-semibold': 600,
  'font-bold': 700,
  'font-extrabold': 800,
  'font-black': 900,
};

// Project-remapped radii: globals.css sets --radius: 10px; the @theme block
// derives sm=6, md=8, lg=10, xl=14, 2xl=18, 3xl=22. Bare `rounded` is the
// Tailwind stock 4px.
const RADII: Record<string, number> = {
  rounded: 4,
  'rounded-none': 0,
  'rounded-sm': 6,
  'rounded-md': 8,
  'rounded-lg': 10,
  'rounded-xl': 14,
  'rounded-2xl': 18,
  'rounded-3xl': 22,
  'rounded-full': 9999,
};

const SHADOWS: Record<string, ResolvedStyle['shadow']> = {
  'shadow-xs': { radius: 1, y: 1, alpha: 0.05 },
  'shadow-sm': { radius: 2, y: 1, alpha: 0.05 },
  shadow: { radius: 3, y: 1, alpha: 0.1 },
  'shadow-md': { radius: 6, y: 4, alpha: 0.1 },
  'shadow-lg': { radius: 10, y: 8, alpha: 0.1 },
};

// `bg-primary/50`, `text-foreground/80`, `border-border/60`, `bg-white`,
// `text-black`, `bg-transparent`.
function parseColorUtility(value: string): RGBA | null {
  const [name, alphaPart] = value.split('/');
  let color: RGBA | null = null;
  if (isThemeToken(name)) color = TANGO_THEME[name];
  else if (name === 'white') color = rgba(255, 255, 255);
  else if (name === 'black') color = rgba(0, 0, 0);
  else if (name === 'transparent') color = TRANSPARENT;
  if (!color) return null;
  if (alphaPart !== undefined) {
    const n = Number(alphaPart);
    if (!Number.isFinite(n) || n < 0 || n > 100) return null;
    return withAlpha(color, n / 100);
  }
  return color;
}

function spacingPx(raw: string): number | null {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return null;
  return n * 4; // Tailwind spacing scale
}

function emptyPadding() {
  return { top: 0, right: 0, bottom: 0, left: 0 };
}

function applyClassName(style: ResolvedStyle, className: string): void {
  for (const cls of className.split(/\s+/).filter(Boolean)) {
    // colors
    if (cls.startsWith('bg-')) {
      const c = parseColorUtility(cls.slice(3));
      if (c) {
        style.backgroundColor = c;
        style.gradient = undefined;
      }
      continue;
    }
    if (cls.startsWith('border-')) {
      const rest = cls.slice(7);
      if (rest === 'dashed') {
        style.borderDashed = true;
        continue;
      }
      if (rest === 'solid') {
        style.borderDashed = false;
        continue;
      }
      if (/^\d+$/.test(rest)) {
        style.borderWidth = Number(rest);
        if (!style.borderColor) style.borderColor = TANGO_THEME.border;
        continue;
      }
      const c = parseColorUtility(rest);
      if (c) {
        style.borderColor = c;
        if (style.borderWidth === undefined) style.borderWidth = 1;
      }
      continue;
    }
    if (cls === 'border') {
      style.borderWidth = 1;
      if (!style.borderColor) style.borderColor = TANGO_THEME.border;
      continue;
    }
    if (cls.startsWith('text-')) {
      if (cls in TEXT_SIZES) {
        style.fontSize = TEXT_SIZES[cls];
        continue;
      }
      const rest = cls.slice(5);
      if (rest === 'left') {
        style.textAlign = 'leading';
        continue;
      }
      if (rest === 'center') {
        style.textAlign = 'center';
        continue;
      }
      if (rest === 'right') {
        style.textAlign = 'trailing';
        continue;
      }
      const c = parseColorUtility(rest);
      if (c) style.textColor = c;
      continue;
    }
    // typography
    if (cls in FONT_WEIGHTS) {
      style.fontWeight = FONT_WEIGHTS[cls];
      continue;
    }
    if (cls === 'font-sans' || cls === 'font-serif' || cls === 'font-mono') {
      style.fontFamily = cls.slice(5) as ResolvedStyle['fontFamily'];
      continue;
    }
    if (cls === 'italic') {
      style.italic = true;
      continue;
    }
    if (cls === 'not-italic') {
      style.italic = false;
      continue;
    }
    // radius / shadow / opacity
    if (cls in RADII) {
      style.cornerRadius = RADII[cls];
      continue;
    }
    if (cls in SHADOWS) {
      style.shadow = SHADOWS[cls];
      continue;
    }
    if (cls === 'shadow-none') {
      style.shadow = undefined;
      continue;
    }
    if (cls.startsWith('opacity-')) {
      const n = Number(cls.slice(8));
      if (Number.isFinite(n) && n >= 0 && n <= 100) style.opacity = n / 100;
      continue;
    }
    // padding
    const pad = /^p([trblxy]?)-(\d+(?:\.\d+)?)$/.exec(cls);
    if (pad) {
      const px = spacingPx(pad[2]);
      if (px == null) continue;
      const p = style.padding ?? emptyPadding();
      switch (pad[1]) {
        case '':
          style.padding = { top: px, right: px, bottom: px, left: px };
          break;
        case 'x':
          style.padding = { ...p, left: px, right: px };
          break;
        case 'y':
          style.padding = { ...p, top: px, bottom: px };
          break;
        case 't':
          style.padding = { ...p, top: px };
          break;
        case 'r':
          style.padding = { ...p, right: px };
          break;
        case 'b':
          style.padding = { ...p, bottom: px };
          break;
        case 'l':
          style.padding = { ...p, left: px };
          break;
      }
      continue;
    }
    // everything else (layout classes, unknown utilities): ignored by policy
  }
}

// ── inline style overlay ──────────────────────────────────────────────────

function asPx(v: string | number): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const m = /^(-?\d+(?:\.\d+)?)(?:px)?$/.exec(v.trim());
  return m ? Number(m[1]) : null;
}

function parsePaddingShorthand(
  v: string | number,
): ResolvedStyle['padding'] | null {
  if (typeof v === 'number') {
    return { top: v, right: v, bottom: v, left: v };
  }
  const parts = v.trim().split(/\s+/).map(asPx);
  if (parts.some((p) => p == null)) return null;
  const n = parts as number[];
  if (n.length === 1) return { top: n[0], right: n[0], bottom: n[0], left: n[0] };
  if (n.length === 2) return { top: n[0], right: n[1], bottom: n[0], left: n[1] };
  if (n.length === 3) return { top: n[0], right: n[1], bottom: n[2], left: n[1] };
  if (n.length === 4) return { top: n[0], right: n[1], bottom: n[2], left: n[3] };
  return null;
}

function parseFontWeight(v: string | number): ResolvedStyle['fontWeight'] | null {
  const n = typeof v === 'number' ? v : v === 'bold' ? 700 : v === 'normal' ? 400 : Number(v);
  if (!Number.isFinite(n)) return null;
  const snapped = Math.min(900, Math.max(100, Math.round(n / 100) * 100));
  return snapped as ResolvedStyle['fontWeight'];
}

// Best-effort `boxShadow: "0 8px 32px rgba(99, 91, 255, 0.24)"`.
function parseBoxShadow(v: string): ResolvedStyle['shadow'] | null {
  const m =
    /(-?\d+(?:\.\d+)?)(?:px)?\s+(-?\d+(?:\.\d+)?)(?:px)?\s+(\d+(?:\.\d+)?)(?:px)?/.exec(
      v,
    );
  if (!m) return null;
  const y = Number(m[2]);
  const radius = Number(m[3]);
  const colorMatch = /(rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}|oklch\([^)]*\))/.exec(v);
  const color = colorMatch ? parseCssColor(colorMatch[1]) : null;
  return { radius, y, alpha: color ? color.a : 0.15 };
}

function applyInlineStyle(
  style: ResolvedStyle,
  inline: NonNullable<UINode['style']>,
): void {
  for (const [key, raw] of Object.entries(inline)) {
    if (raw === null || raw === undefined) continue;
    switch (key) {
      case 'backgroundColor': {
        const c = typeof raw === 'string' ? parseCssColor(raw) : null;
        if (c) {
          style.backgroundColor = c;
          style.gradient = undefined;
        }
        break;
      }
      case 'background': {
        if (typeof raw !== 'string') break;
        const g = parseLinearGradient(raw);
        if (g) {
          style.gradient = g;
          style.backgroundColor = undefined;
          break;
        }
        const c = parseCssColor(raw);
        if (c) {
          style.backgroundColor = c;
          style.gradient = undefined;
        }
        break;
      }
      case 'color': {
        const c = typeof raw === 'string' ? parseCssColor(raw) : null;
        if (c) style.textColor = c;
        break;
      }
      case 'borderColor': {
        const c = typeof raw === 'string' ? parseCssColor(raw) : null;
        if (c) {
          style.borderColor = c;
          if (style.borderWidth === undefined) style.borderWidth = 1;
        }
        break;
      }
      case 'borderWidth': {
        const n = asPx(raw);
        if (n != null) style.borderWidth = n;
        break;
      }
      case 'borderStyle': {
        if (raw === 'dashed') style.borderDashed = true;
        else if (raw === 'solid') style.borderDashed = false;
        break;
      }
      case 'borderRadius': {
        if (typeof raw === 'string' && raw.trim().endsWith('%')) {
          style.cornerRadius = 9999;
          break;
        }
        const n = asPx(raw);
        if (n != null) style.cornerRadius = n;
        break;
      }
      case 'fontSize': {
        const n = asPx(raw);
        if (n != null) style.fontSize = n;
        break;
      }
      case 'fontWeight': {
        const w = parseFontWeight(raw);
        if (w != null) style.fontWeight = w;
        break;
      }
      case 'fontStyle': {
        if (raw === 'italic') style.italic = true;
        break;
      }
      case 'textAlign': {
        if (raw === 'left') style.textAlign = 'leading';
        else if (raw === 'center') style.textAlign = 'center';
        else if (raw === 'right') style.textAlign = 'trailing';
        break;
      }
      case 'opacity': {
        const n = typeof raw === 'number' ? raw : Number(raw);
        if (Number.isFinite(n) && n >= 0 && n <= 1) style.opacity = n;
        break;
      }
      case 'padding': {
        const p = parsePaddingShorthand(raw);
        if (p) style.padding = p;
        break;
      }
      case 'paddingTop':
      case 'paddingRight':
      case 'paddingBottom':
      case 'paddingLeft': {
        const n = asPx(raw);
        if (n == null) break;
        const p = style.padding ?? emptyPadding();
        const side = key.slice(7).toLowerCase() as 'top' | 'right' | 'bottom' | 'left';
        style.padding = { ...p, [side]: n };
        break;
      }
      case 'boxShadow': {
        if (typeof raw !== 'string') break;
        const s = parseBoxShadow(raw);
        if (s) style.shadow = s;
        break;
      }
      default:
        // Layout keys were already stripped by the renderer's policy; anything
        // else unrecognized is ignored.
        break;
    }
  }
}

// ── per-node resolution ───────────────────────────────────────────────────

const KIND_MAP: Record<UINode['type'], ResolvedNodeKind> = {
  div: 'box',
  text: 'text',
  heading: 'text',
  Button: 'button',
  Input: 'input',
  Textarea: 'textarea',
  Badge: 'badge',
  Separator: 'separator',
  Image: 'image',
  Icon: 'icon',
};

export function resolveNodeStyle(node: UINode): ResolvedStyle {
  const style = baselineFor(node);
  if (node.className) applyClassName(style, node.className);
  if (node.style) applyInlineStyle(style, node.style);
  return style;
}

export function resolveNode(node: UINode): ResolvedNode {
  const resolved: ResolvedNode = {
    id: node.id,
    kind: KIND_MAP[node.type] ?? 'box',
    x: node.x,
    y: node.y,
    width: node.width,
    height: node.height,
    style: resolveNodeStyle(node),
  };

  switch (node.type) {
    case 'text':
    case 'heading':
      resolved.text = node.text ?? '';
      break;
    case 'Button':
      resolved.text = node.text ?? 'Button';
      break;
    case 'Badge':
      resolved.text = node.text ?? 'Badge';
      break;
    case 'Input':
    case 'Textarea': {
      const placeholder =
        typeof node.props?.placeholder === 'string'
          ? node.props.placeholder
          : (node.text ?? 'Placeholder');
      resolved.text = placeholder;
      resolved.isPlaceholderText = true;
      break;
    }
    case 'Separator':
      resolved.separatorVertical = node.props?.orientation === 'vertical';
      break;
    case 'Image': {
      const src = typeof node.props?.src === 'string' ? node.props.src : null;
      // http(s) only: data: URLs would bloat the wire format and AsyncImage
      // can't load them anyway; the placeholder box renders instead.
      if (src && /^https?:\/\//i.test(src)) resolved.imageSrc = src;
      break;
    }
    case 'Icon': {
      const name =
        typeof node.props?.iconName === 'string' ? node.props.iconName : null;
      resolved.sfSymbol = lucideToSfSymbol(name);
      break;
    }
  }
  return resolved;
}

export function resolveScreen(screen: UIScreen): ResolvedScreen {
  return {
    id: screen.id,
    title: screen.title,
    frame: { w: screen.frame.w, h: screen.frame.h },
    nodes: screen.nodes.map(resolveNode),
  };
}

export function resolveSpec(spec: UISpec): ResolvedSpec {
  return { version: 1, screens: spec.screens.map(resolveScreen) };
}
