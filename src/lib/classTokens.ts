// Pure className token-swap helpers behind the shape style quick controls.
// Edits are expressed as Tailwind theme-token classes (bg-primary, border-2,
// rounded-lg…) — the same vocabulary the agent and the style resolver speak —
// so a swatch click round-trips cleanly through export and the agent can read
// back what the human chose. Off-theme inline-style values for the same
// property are stripped when a token is applied (inline style wins in the
// resolver, so leaving them would make the swatch appear to do nothing).

import type { UINode } from './uiMockProtocol';

// Class families the quick controls own. Bare `border` lives in the width
// family (it implies width 1); border-dashed/solid stay untouched.
const FILL_RE = /^bg-/;
const BORDER_COLOR_RE = /^border-(?!\d+$)(?!dashed$)(?!solid$)./;
const BORDER_WIDTH_RE = /^border(-\d+)?$/;
const RADIUS_RE = /^rounded(-.+)?$/;

// `family` is anything with a RegExp-shaped `.test` — lets composite
// families (e.g. text colors = `text-*` minus sizes/aligns) plug in.
export function swapClassToken(
  className: string | undefined,
  family: { test: (cls: string) => boolean },
  replacement: string | null,
): string | undefined {
  const parts = (className ?? '')
    .split(/\s+/)
    .filter(Boolean)
    .filter((cls) => !family.test(cls));
  if (replacement) parts.push(replacement);
  return parts.length > 0 ? parts.join(' ') : undefined;
}

function withoutStyleKeys(
  style: UINode['style'],
  keys: string[],
): UINode['style'] {
  if (!style) return undefined;
  const out: Record<string, string | number> = {};
  for (const [k, v] of Object.entries(style)) {
    if (!keys.includes(k)) out[k] = v;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

// Each helper returns a Partial<UINode> patch for updateNodes/update_ui_node.
// `style` is always present in the patch (possibly undefined) so a stripped
// inline override actually clears — patch merge is shallow.

export function applyFill(node: UINode, token: string | null): Partial<UINode> {
  return {
    className: swapClassToken(
      node.className,
      FILL_RE,
      token ? `bg-${token}` : 'bg-transparent',
    ),
    style: withoutStyleKeys(node.style, ['backgroundColor', 'background']),
  };
}

export function applyStrokeColor(
  node: UINode,
  token: string,
): Partial<UINode> {
  return {
    className: swapClassToken(node.className, BORDER_COLOR_RE, `border-${token}`),
    style: withoutStyleKeys(node.style, ['borderColor']),
  };
}

export function applyStrokeWidth(node: UINode, width: number): Partial<UINode> {
  return {
    className: swapClassToken(node.className, BORDER_WIDTH_RE, `border-${width}`),
    style: withoutStyleKeys(node.style, ['borderWidth']),
  };
}

export function applyRadius(
  node: UINode,
  radiusClass: string | null,
): Partial<UINode> {
  return {
    className: swapClassToken(node.className, RADIUS_RE, radiusClass),
    style: withoutStyleKeys(node.style, ['borderRadius']),
  };
}

// Active-state probes for the controls (exact class match in the family).
export function hasClass(node: UINode, cls: string): boolean {
  return (node.className ?? '').split(/\s+/).includes(cls);
}

// ── inspector additions ─────────────────────────────────────────────────────

// text-* color utilities: the `text-` family minus sizes and alignment.
const TEXT_SIZES = new Set([
  'text-xs', 'text-sm', 'text-base', 'text-lg', 'text-xl',
  'text-2xl', 'text-3xl', 'text-4xl',
]);
const TEXT_ALIGNS = new Set(['text-left', 'text-center', 'text-right']);
const TEXT_COLOR_RE = {
  test: (cls: string) =>
    cls.startsWith('text-') && !TEXT_SIZES.has(cls) && !TEXT_ALIGNS.has(cls),
} as const;
const TEXT_ALIGN_RE = /^text-(left|center|right)$/;
const FONT_WEIGHT_RE =
  /^font-(thin|extralight|light|normal|medium|semibold|bold|extrabold|black)$/;

export function applyTextColor(node: UINode, token: string): Partial<UINode> {
  return {
    className: swapClassToken(node.className, TEXT_COLOR_RE, `text-${token}`),
    style: withoutStyleKeys(node.style, ['color']),
  };
}

export function applyTextAlign(
  node: UINode,
  align: 'left' | 'center' | 'right',
): Partial<UINode> {
  return {
    className: swapClassToken(node.className, TEXT_ALIGN_RE, `text-${align}`),
    style: withoutStyleKeys(node.style, ['textAlign']),
  };
}

// `weightClass` is a full utility ('font-semibold'); null restores baseline.
export function applyFontWeight(
  node: UINode,
  weightClass: string | null,
): Partial<UINode> {
  return {
    className: swapClassToken(node.className, FONT_WEIGHT_RE, weightClass),
    style: withoutStyleKeys(node.style, ['fontWeight']),
  };
}

// Set (or with null, clear) one inline-style key, preserving the rest. The
// channel for values className tokens can't carry: exact hex colors,
// arbitrary px radii/font sizes, fractional opacity.
export function setStyleKey(
  node: UINode,
  key: string,
  value: string | number | null,
): Partial<UINode> {
  const without = withoutStyleKeys(node.style, [key]);
  if (value === null) return { style: without };
  return { style: { ...(without ?? {}), [key]: value } };
}

// Custom (off-theme) fill: hex into style.backgroundColor, bg-* classes out
// of the way so the inline value isn't fighting a token.
export function applyFillColor(node: UINode, hex: string): Partial<UINode> {
  const cleared = swapClassToken(node.className, /^bg-/, null);
  const without = withoutStyleKeys(node.style, ['backgroundColor', 'background']);
  return {
    className: cleared,
    style: { ...(without ?? {}), backgroundColor: hex },
  };
}

export function applyStrokeColorHex(node: UINode, hex: string): Partial<UINode> {
  const cleared = swapClassToken(
    node.className,
    /^border-(?!\d+$)(?!dashed$)(?!solid$)./,
    null,
  );
  const without = withoutStyleKeys(node.style, ['borderColor']);
  return {
    className: cleared,
    style: { ...(without ?? {}), borderColor: hex },
  };
}
