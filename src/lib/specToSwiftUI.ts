// Deterministic UISpec → SwiftUI code generator. No LLM anywhere in this
// path: the same spec produces byte-identical files, every time (asserted by
// tests). Consumes resolveSpec() so every styling decision is shared with the
// preview host.
//
// Layout convention (mirrored by the preview host's Swift renderer):
//   ZStack(alignment: .topLeading) { node.frame(w,h).offset(x,y) }
// `.offset` from the top-leading anchor maps the spec's top-left (x, y) 1:1.
// We deliberately avoid `.position` — it's center-based, which would force
// (x + w/2, y + h/2) conversions in two codebases and is a classic
// off-by-half bug source.
//
// Output files (fixed order):
//   1. TangoSupport.swift        — Color/gradient helpers (static content)
//   2. <TypeName>.swift          — one per screen, struct <TypeName>: View
//   3. TangoGeneratedIndex.swift — TangoGeneratedRootView (TabView over all)
//
// Every file opens with the `tango:generated` marker — load-bearing: the
// export step deletes stale marked files, and the docs tell agents and humans
// these files are tango-owned (overwritten on every export).

import type { UISpec } from './uiMockProtocol';
import {
  type ResolvedNode,
  type ResolvedScreen,
  type ResolvedStyle,
  resolveSpec,
} from './uiResolve';
import type { Gradient, RGBA } from './themeColors';
import { TANGO_THEME } from './themeColors';

export type GeneratedFile = {
  /** Path relative to the TangoGenerated/ output dir. */
  path: string;
  content: string;
};

export type SwiftCodegenOpts = {
  /** Extra note appended to each file header. Keep deterministic — no dates. */
  headerNote?: string;
};

// ── primitives ────────────────────────────────────────────────────────────

// Integers bare, non-integers with ≤3 decimals trimmed — keeps output stable
// and diffs readable.
export function fmt(n: number): string {
  if (Number.isInteger(n)) return String(n);
  const s = n.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
  return s === '-0' ? '0' : s;
}

export function swiftStringLiteral(s: string): string {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0)!;
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (code < 0x20) out += `\\u{${code.toString(16).toUpperCase()}}`;
    else out += ch;
  }
  return out + '"';
}

// PascalCase a screen id into a unique Swift type name. Prefixed `Tango` so
// generated types can't collide with the user's own Views (the import flow
// names screens after real View types). `taken` is mutated.
export function screenTypeName(id: string, taken: Set<string>): string {
  const pascal = id
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join('');
  let base = `Tango${pascal || 'Screen'}`;
  if (!/(Screen|View)$/.test(base)) base += 'Screen';
  let name = base;
  let i = 2;
  while (taken.has(name)) {
    name = `${base}${i}`;
    i += 1;
  }
  taken.add(name);
  return name;
}

function swiftColor(c: RGBA): string {
  return `Color(tangoR: ${c.r}, g: ${c.g}, b: ${c.b}, a: ${fmt(c.a)})`;
}

// CSS gradient angle (0deg = to top, clockwise) → SwiftUI UnitPoints.
function gradientPoints(angleDeg: number): { start: string; end: string } {
  const rad = (angleDeg * Math.PI) / 180;
  // Unit direction of the gradient line in a y-down coordinate space.
  const dx = Math.sin(rad);
  const dy = -Math.cos(rad);
  const sx = 0.5 - dx / 2;
  const sy = 0.5 - dy / 2;
  const ex = 0.5 + dx / 2;
  const ey = 0.5 + dy / 2;
  return {
    start: `UnitPoint(x: ${fmt(sx)}, y: ${fmt(sy)})`,
    end: `UnitPoint(x: ${fmt(ex)}, y: ${fmt(ey)})`,
  };
}

function swiftGradient(g: Gradient): string {
  const { start, end } = gradientPoints(g.angleDeg);
  const stops = g.stops
    .map((s) => `.init(color: ${swiftColor(s.color)}, location: ${fmt(s.at)})`)
    .join(', ');
  return `LinearGradient(stops: [${stops}], startPoint: ${start}, endPoint: ${end})`;
}

const FONT_WEIGHTS: Record<number, string> = {
  100: '.ultraLight',
  200: '.thin',
  300: '.light',
  400: '.regular',
  500: '.medium',
  600: '.semibold',
  700: '.bold',
  800: '.heavy',
  900: '.black',
};

function fontModifier(style: ResolvedStyle): string | null {
  if (style.fontSize === undefined && style.fontWeight === undefined) {
    return null;
  }
  const size = fmt(style.fontSize ?? 14);
  const weight = FONT_WEIGHTS[style.fontWeight ?? 400] ?? '.regular';
  const design =
    style.fontFamily === 'serif'
      ? ', design: .serif'
      : style.fontFamily === 'mono'
        ? ', design: .monospaced'
        : '';
  return `.font(.system(size: ${size}, weight: ${weight}${design}))`;
}

function isVisible(c: RGBA | undefined): c is RGBA {
  return c !== undefined && c.a > 0;
}

function shapeExpr(style: ResolvedStyle): string {
  const r = style.cornerRadius ?? 0;
  if (r >= 9999) return 'Capsule()';
  if (r > 0) return `RoundedRectangle(cornerRadius: ${fmt(r)})`;
  return 'Rectangle()';
}

function backgroundModifier(style: ResolvedStyle): string | null {
  const shape = shapeExpr(style);
  if (style.gradient) {
    return `.background(${shape}.fill(${swiftGradient(style.gradient)}))`;
  }
  if (isVisible(style.backgroundColor)) {
    return `.background(${shape}.fill(${swiftColor(style.backgroundColor)}))`;
  }
  return null;
}

function borderModifier(style: ResolvedStyle): string | null {
  if (!style.borderWidth || style.borderWidth <= 0) return null;
  const color = style.borderColor ?? TANGO_THEME.border;
  const shape = shapeExpr(style);
  const stroke = style.borderDashed
    ? `style: StrokeStyle(lineWidth: ${fmt(style.borderWidth)}, dash: [4])`
    : `lineWidth: ${fmt(style.borderWidth)}`;
  return `.overlay(${shape}.strokeBorder(${swiftColor(color)}, ${stroke}))`;
}

function shadowModifier(style: ResolvedStyle): string | null {
  if (!style.shadow) return null;
  const { radius, y, alpha } = style.shadow;
  return `.shadow(color: .black.opacity(${fmt(alpha)}), radius: ${fmt(radius)}, x: 0, y: ${fmt(y)})`;
}

type FrameAlignment =
  | 'topLeading'
  | 'top'
  | 'topTrailing'
  | 'leading'
  | 'center'
  | 'trailing';

function frameModifier(node: ResolvedNode, alignment?: FrameAlignment): string {
  const align = alignment ? `, alignment: .${alignment}` : '';
  return `.frame(width: ${fmt(node.width)}, height: ${fmt(node.height)}${align})`;
}

function offsetModifier(node: ResolvedNode): string {
  return `.offset(x: ${fmt(node.x)}, y: ${fmt(node.y)})`;
}

function textAlignToFrameAlignment(
  style: ResolvedStyle,
  vertical: 'top' | 'center',
): FrameAlignment {
  const h = style.textAlign ?? 'leading';
  if (vertical === 'top') {
    return h === 'center' ? 'top' : h === 'trailing' ? 'topTrailing' : 'topLeading';
  }
  return h === 'center' ? 'center' : h === 'trailing' ? 'trailing' : 'leading';
}

function multilineAlignment(style: ResolvedStyle): string | null {
  if (style.textAlign === 'center') return '.multilineTextAlignment(.center)';
  if (style.textAlign === 'trailing') return '.multilineTextAlignment(.trailing)';
  return null;
}

// Assemble `base + modifiers` with two-space indentation per line.
function withModifiers(base: string, modifiers: Array<string | null>): string {
  const mods = modifiers.filter((m): m is string => m !== null);
  if (mods.length === 0) return base;
  // base may be multi-line (ZStack literals); modifiers attach at its end.
  return base + '\n' + mods.map((m) => `  ${m}`).join('\n');
}

function indent(code: string, levels: number): string {
  const pad = '  '.repeat(levels);
  return code
    .split('\n')
    .map((l) => (l.length > 0 ? pad + l : l))
    .join('\n');
}

// ── per-kind emitters ─────────────────────────────────────────────────────
// Each returns a complete view expression (no trailing offset — added by the
// caller so the convention lives in exactly one place).

// Shape + fill + border, no frame — shared by the box emitter and the image
// placeholder (which wraps it in a ZStack and frames the ZStack instead).
function boxChrome(s: ResolvedStyle): string {
  const shape = shapeExpr(s);
  const fill = s.gradient
    ? `.fill(${swiftGradient(s.gradient)})`
    : `.fill(${isVisible(s.backgroundColor) ? swiftColor(s.backgroundColor) : 'Color.clear'})`;
  return withModifiers(`${shape}\n  ${fill}`, [borderModifier(s)]);
}

function emitBox(node: ResolvedNode): string {
  return withModifiers(boxChrome(node.style), [
    shadowModifier(node.style),
    frameModifier(node),
  ]);
}

function emitText(node: ResolvedNode): string {
  const s = node.style;
  return withModifiers(`Text(${swiftStringLiteral(node.text ?? '')})`, [
    fontModifier(s),
    s.italic ? '.italic()' : null,
    isVisible(s.textColor) ? `.foregroundColor(${swiftColor(s.textColor)})` : null,
    multilineAlignment(s),
    frameModifier(node, textAlignToFrameAlignment(s, 'top')),
    backgroundModifier(s),
    borderModifier(s),
    shadowModifier(s),
  ]);
}

function emitButton(node: ResolvedNode): string {
  const s = node.style;
  const label = withModifiers(
    `Text(${swiftStringLiteral(node.text ?? 'Button')})`,
    [fontModifier(s), s.italic ? '.italic()' : null],
  );
  const base = `Button(action: {}) {\n${indent(label, 1)}\n}`;
  return withModifiers(base, [
    isVisible(s.textColor) ? `.foregroundColor(${swiftColor(s.textColor)})` : null,
    frameModifier(node),
    backgroundModifier(s),
    borderModifier(s),
    shadowModifier(s),
  ]);
}

function emitInput(node: ResolvedNode): string {
  const s = node.style;
  const padding = s.padding?.left ?? 12;
  return withModifiers(
    `TextField(${swiftStringLiteral(node.text ?? '')}, text: .constant(""))`,
    [
      '.textFieldStyle(.plain)',
      fontModifier(s) ?? '.font(.system(size: 14))',
      `.padding(.horizontal, ${fmt(padding)})`,
      frameModifier(node),
      backgroundModifier(s),
      borderModifier(s),
      shadowModifier(s),
    ],
  );
}

function emitTextarea(node: ResolvedNode): string {
  const s = node.style;
  const pad = s.padding ?? { top: 8, right: 12, bottom: 8, left: 12 };
  const placeholder = withModifiers(
    `Text(${swiftStringLiteral(node.text ?? '')})`,
    [
      fontModifier(s) ?? '.font(.system(size: 14))',
      isVisible(s.textColor) ? `.foregroundColor(${swiftColor(s.textColor)})` : null,
      `.padding(EdgeInsets(top: ${fmt(pad.top)}, leading: ${fmt(pad.left)}, bottom: ${fmt(pad.bottom)}, trailing: ${fmt(pad.right)}))`,
      '.allowsHitTesting(false)',
    ],
  );
  const base = `TextEditor(text: .constant(""))\n  .scrollContentBackground(.hidden)\n  .overlay(alignment: .topLeading) {\n${indent(placeholder, 2)}\n  }`;
  return withModifiers(base, [
    frameModifier(node),
    backgroundModifier(s),
    borderModifier(s),
    shadowModifier(s),
  ]);
}

function emitBadge(node: ResolvedNode): string {
  const s = node.style;
  const pad = s.padding ?? { top: 2, right: 8, bottom: 2, left: 8 };
  // The badge hugs its label (web: w-fit centered inside the node box), so the
  // chrome attaches to the Text and the node frame just centers it.
  const label = withModifiers(`Text(${swiftStringLiteral(node.text ?? 'Badge')})`, [
    fontModifier(s),
    isVisible(s.textColor) ? `.foregroundColor(${swiftColor(s.textColor)})` : null,
    `.padding(EdgeInsets(top: ${fmt(pad.top)}, leading: ${fmt(pad.left)}, bottom: ${fmt(pad.bottom)}, trailing: ${fmt(pad.right)}))`,
    backgroundModifier(s),
    borderModifier(s),
  ]);
  return withModifiers(label, [frameModifier(node, 'center')]);
}

function emitSeparator(node: ResolvedNode): string {
  const s = node.style;
  const color = isVisible(s.backgroundColor)
    ? s.backgroundColor
    : TANGO_THEME.border;
  const bar = node.separatorVertical
    ? `.frame(width: 1, height: ${fmt(node.height)})`
    : `.frame(width: ${fmt(node.width)}, height: 1)`;
  return withModifiers(`Rectangle()\n  .fill(${swiftColor(color)})\n  ${bar}`, [
    frameModifier(node, 'center'),
  ]);
}

function emitImage(node: ResolvedNode): string {
  const s = node.style;
  if (node.imageSrc) {
    const clip =
      (s.cornerRadius ?? 0) > 0
        ? `.clipShape(${shapeExpr(s)})`
        : '.clipped()';
    const base = `AsyncImage(url: URL(string: ${swiftStringLiteral(node.imageSrc)})) { image in\n  image.resizable().scaledToFill()\n} placeholder: {\n  ${swiftColor(TANGO_THEME.muted)}\n}`;
    return withModifiers(base, [frameModifier(node), clip, shadowModifier(s)]);
  }
  // Placeholder: dashed box + photo glyph (mirrors the web mock).
  const glyph = `Image(systemName: "photo")\n  .foregroundColor(${swiftColor(s.textColor ?? TANGO_THEME['muted-foreground'])})`;
  const base = `ZStack {\n${indent(boxChrome(s), 1)}\n${indent(glyph, 1)}\n}`;
  return withModifiers(base, [frameModifier(node)]);
}

function emitIcon(node: ResolvedNode): string {
  const s = node.style;
  return withModifiers(
    `Image(systemName: ${swiftStringLiteral(node.sfSymbol ?? 'circle')})\n  .resizable()\n  .scaledToFit()`,
    [
      isVisible(s.textColor) ? `.foregroundColor(${swiftColor(s.textColor)})` : null,
      frameModifier(node),
    ],
  );
}

function emitNode(node: ResolvedNode): string {
  let expr: string;
  switch (node.kind) {
    case 'box':
      expr = emitBox(node);
      break;
    case 'text':
      expr = emitText(node);
      break;
    case 'button':
      expr = emitButton(node);
      break;
    case 'input':
      expr = emitInput(node);
      break;
    case 'textarea':
      expr = emitTextarea(node);
      break;
    case 'badge':
      expr = emitBadge(node);
      break;
    case 'separator':
      expr = emitSeparator(node);
      break;
    case 'image':
      expr = emitImage(node);
      break;
    case 'icon':
      expr = emitIcon(node);
      break;
    default:
      expr = emitBox(node);
  }
  const opacity =
    node.style.opacity !== undefined ? `  .opacity(${fmt(node.style.opacity)})` : null;
  return [expr, opacity, `  ${offsetModifier(node)}`]
    .filter((p): p is string => p !== null)
    .join('\n');
}

// SwiftUI's @ViewBuilder accepts at most 10 children per block — chunk node
// expressions into nested Group { } blocks so any node count compiles.
function chunkIntoGroups(exprs: string[]): string {
  if (exprs.length <= 10) return exprs.join('\n');
  const groups: string[] = [];
  for (let i = 0; i < exprs.length; i += 10) {
    const slice = exprs.slice(i, i + 10);
    groups.push(`Group {\n${indent(slice.join('\n'), 1)}\n}`);
  }
  return chunkIntoGroups(groups);
}

// ── file assembly ─────────────────────────────────────────────────────────

export const GENERATED_MARKER = 'tango:generated';

function fileHeader(tag: string, note?: string): string {
  const lines = [
    '// Generated by tango — DO NOT EDIT.',
    `// ${GENERATED_MARKER} v=1 screen=${tag}`,
    '// Regenerated on every "Export & Run"; change the design in tango instead.',
  ];
  if (note) lines.push(`// ${note}`);
  return lines.join('\n') + '\n\n';
}

const SUPPORT_SWIFT = `import SwiftUI

extension Color {
  /// sRGB color from 0–255 channels — emitted by tango's deterministic codegen.
  init(tangoR r: Int, g: Int, b: Int, a: Double) {
    self.init(
      .sRGB,
      red: Double(r) / 255.0,
      green: Double(g) / 255.0,
      blue: Double(b) / 255.0,
      opacity: a
    )
  }
}
`;

function emitScreen(screen: ResolvedScreen, typeName: string, note?: string): string {
  const nodes = screen.nodes.map(emitNode);
  const body =
    nodes.length === 0
      ? indent('EmptyView()', 3)
      : indent(chunkIntoGroups(nodes), 3);
  const bg = swiftColor(TANGO_THEME.background);
  return (
    fileHeader(screen.id, note) +
    `import SwiftUI

/// ${screen.title.replace(/\n/g, ' ')} — ${fmt(screen.frame.w)}×${fmt(screen.frame.h)}
struct ${typeName}: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
${body}
    }
    .frame(width: ${fmt(screen.frame.w)}, height: ${fmt(screen.frame.h)}, alignment: .topLeading)
    .background(${bg})
    .clipped()
  }
}

#Preview {
  ${typeName}()
}
`
  );
}

function emitIndex(
  screens: Array<{ screen: ResolvedScreen; typeName: string }>,
  note?: string,
): string {
  const tabs = screens
    .map(
      ({ screen, typeName }) =>
        `      ${typeName}()\n        .tabItem { Text(${swiftStringLiteral(screen.title)}) }`,
    )
    .join('\n');
  const body =
    screens.length === 0
      ? '    EmptyView()'
      : `    TabView {\n${tabs}\n    }`;
  return (
    fileHeader('index', note) +
    `import SwiftUI

/// Root view over every tango-generated screen. Embed this (or the individual
/// screen views) wherever the design should appear.
struct TangoGeneratedRootView: View {
  var body: some View {
${body}
  }
}

#Preview {
  TangoGeneratedRootView()
}
`
  );
}

export function specToSwiftUI(
  spec: UISpec,
  opts?: SwiftCodegenOpts,
): { files: GeneratedFile[]; embedTypeNames: string[] } {
  const resolved = resolveSpec(spec);
  const taken = new Set<string>(['TangoGeneratedRootView']);
  const screens = resolved.screens.map((screen) => ({
    screen,
    typeName: screenTypeName(screen.id, taken),
  }));

  const files: GeneratedFile[] = [
    {
      path: 'TangoSupport.swift',
      content: fileHeader('support', opts?.headerNote) + SUPPORT_SWIFT,
    },
    ...screens.map(({ screen, typeName }) => ({
      path: `${typeName}.swift`,
      content: emitScreen(screen, typeName, opts?.headerNote),
    })),
    {
      path: 'TangoGeneratedIndex.swift',
      content: emitIndex(screens, opts?.headerNote),
    },
  ];
  // The view types user code can reference to actually show the design —
  // generated screens render nothing until one of these appears in a
  // non-generated Swift file. The export step scans for them to warn when
  // an export would launch an app that looks unchanged.
  const embedTypeNames = [
    'TangoGeneratedRootView',
    ...screens.map(({ typeName }) => typeName),
  ];
  return { files, embedTypeNames };
}
