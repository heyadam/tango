// Deterministic UISpec → SwiftUI code generator. No LLM anywhere in this
// path: the same spec produces byte-identical output, every time (asserted by
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
// This module emits BUILDING BLOCKS for the in-place export (iosExport):
//   - emitScreenBody(): the interior of one screen's `var body` — spliced
//     into the user's own View struct (linked screens) or wrapped in a fresh
//     file (canvas-born screens). Opens with the `tango:body` marker so a
//     later export can prove the body is tango-managed before overwriting,
//     and so import can round-trip the struct back onto the same screen.
//   - emitScreenFile(): a complete new .swift file for a screen with no
//     source tie. The file belongs to the user after creation — only the
//     marked body is tango-managed on subsequent exports.
// Everything emitted is self-contained vanilla SwiftUI (exact sRGB color
// literals, literal path points) — no shared support file to keep in sync.

import type { UIScreen, UISpec } from './uiMockProtocol';
import {
  type ResolvedNode,
  type ResolvedScreen,
  type ResolvedStyle,
} from './uiResolve';
import type { Gradient, RGBA } from './themeColors';
import { TANGO_THEME } from './themeColors';
import { bodyMarkerLine } from './swiftScan';

// ── primitives ────────────────────────────────────────────────────────────

// Integers bare, non-integers with ≤3 decimals trimmed — keeps output stable
// and diffs readable.
export function fmt(n: number): string {
  if (Number.isInteger(n)) return String(n);
  const s = n.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
  return s === '-0' ? '0' : s;
}

// 0–255 channel → 0–1 Double literal. 5 decimals round-trips 8-bit exactly
// (1/255 ≈ 0.00392); precomputed so swiftc never folds divisions inside the
// already-huge body expressions.
export function fmtChannel(n: number): string {
  if (n <= 0) return '0';
  if (n >= 255) return '1';
  return (n / 255).toFixed(5).replace(/0+$/, '').replace(/\.$/, '');
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

function pascalCase(id: string): string {
  return id
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join('');
}

const SWIFT_IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

// PascalCase a screen id into a unique Swift type name for a NEW screen file
// (no prefix — the file is named like any user View). `taken` is mutated, so
// the caller can pre-seed it with names the project already declares.
export function screenTypeName(id: string, taken: Set<string>): string {
  let base = pascalCase(id) || 'Screen';
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

// screenId → '<TypeName>.swift' for every screen in the spec — the DERIVED
// new-file target a screen with no source tie would export to. The single
// home for the order-dependent naming pass, shared by the export pipeline and
// the title-row chip — derive it live from the spec, never store it. Seeded
// with every identifier-shaped screen id so a new file can never collide with
// a linked screen's own struct (import names screens after real View types).
export function screenFileNames(spec: UISpec): Map<string, string> {
  const taken = new Set<string>(
    spec.screens.map((s) => s.id).filter((id) => SWIFT_IDENT_RE.test(id)),
  );
  const names = new Map<string, string>();
  for (const screen of spec.screens) {
    // A screen never collides with its OWN id-as-struct-name seed.
    const seeded = taken.delete(screen.id);
    names.set(screen.id, `${screenTypeName(screen.id, taken)}.swift`);
    if (seeded) taken.add(screen.id);
  }
  return names;
}

// Type names for the screens that need a NEW file (no source tie), deduped
// against `extraTaken` (the project's declared type names) and every
// identifier-shaped screen id — a created struct can never collide with a
// user type or a linked screen's View. Same own-id rule as screenFileNames.
export function newScreenTypeNames(
  spec: UISpec,
  extraTaken: Iterable<string> = [],
): Map<string, string> {
  const taken = new Set<string>(extraTaken);
  for (const s of spec.screens) {
    if (SWIFT_IDENT_RE.test(s.id)) taken.add(s.id);
  }
  const names = new Map<string, string>();
  for (const screen of spec.screens) {
    if (screen.sourceFile) continue;
    const seeded = taken.delete(screen.id);
    names.set(screen.id, screenTypeName(screen.id, taken));
    if (seeded) taken.add(screen.id);
  }
  return names;
}

// Struct names worth trying when locating a linked screen's View in its
// source file, most likely first. Import names screens after the View type
// ("OnboardingView"), so the id itself is usually exact; PascalCase(id) and
// the title cover hand-renamed screens.
export function structCandidates(
  screen: Pick<UIScreen, 'id' | 'title'>,
): string[] {
  const out: string[] = [];
  const push = (s: string) => {
    if (SWIFT_IDENT_RE.test(s) && !out.includes(s)) out.push(s);
  };
  push(screen.id);
  push(pascalCase(screen.id));
  push(screen.title);
  return out;
}

// Exact sRGB literal (Color(red:green:blue:opacity:) defaults to .sRGB) —
// fully self-contained, no support-file initializer to ship alongside.
function swiftColor(c: RGBA): string {
  return `Color(red: ${fmtChannel(c.r)}, green: ${fmtChannel(c.g)}, blue: ${fmtChannel(c.b)}, opacity: ${fmt(c.a)})`;
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

// ── vector shapes ──────────────────────────────────────────────────────────
// Geometry arrives pre-computed in pixel coords on the ResolvedNode
// (shapeGeometry via uiResolve) — emit the literal points, never re-derive.

function fillExpr(s: ResolvedStyle): string {
  if (s.gradient) return swiftGradient(s.gradient);
  return isVisible(s.backgroundColor) ? swiftColor(s.backgroundColor) : 'Color.clear';
}

// Open or closed Path literal from pixel points.
function pathExpr(points: Array<{ x: number; y: number }>, close: boolean): string {
  const lines = points.map((p, i) =>
    i === 0
      ? `p.move(to: CGPoint(x: ${fmt(p.x)}, y: ${fmt(p.y)}))`
      : `p.addLine(to: CGPoint(x: ${fmt(p.x)}, y: ${fmt(p.y)}))`,
  );
  if (close) lines.push('p.closeSubpath()');
  return `Path { p in\n${indent(lines.join('\n'), 1)}\n}`;
}

function lineStrokeStyle(s: ResolvedStyle): string {
  const width = fmt(s.borderWidth ?? 2);
  const dash = s.borderDashed ? ', dash: [4]' : '';
  return `StrokeStyle(lineWidth: ${width}, lineCap: .round, lineJoin: .round${dash})`;
}

function emitEllipse(node: ResolvedNode): string {
  const s = node.style;
  const stroke =
    s.borderWidth && s.borderWidth > 0
      ? `.overlay(Ellipse().strokeBorder(${swiftColor(s.borderColor ?? TANGO_THEME.border)}, ${
          s.borderDashed
            ? `style: StrokeStyle(lineWidth: ${fmt(s.borderWidth)}, dash: [4])`
            : `lineWidth: ${fmt(s.borderWidth)}`
        }))`
      : null;
  return withModifiers(`Ellipse()\n  .fill(${fillExpr(s)})`, [
    stroke,
    shadowModifier(s),
    frameModifier(node),
  ]);
}

function emitPolygon(node: ResolvedNode): string {
  const s = node.style;
  const points = node.shapePoints ?? [];
  const stroke =
    s.borderWidth && s.borderWidth > 0
      ? `.overlay(${pathExpr(points, true)}.stroke(${swiftColor(s.borderColor ?? TANGO_THEME.border)}, style: ${lineStrokeStyle(s)}))`
      : null;
  return withModifiers(`${pathExpr(points, true)}\n  .fill(${fillExpr(s)})`, [
    stroke,
    shadowModifier(s),
    frameModifier(node),
  ]);
}

function emitLine(node: ResolvedNode): string {
  const s = node.style;
  const color = swiftColor(s.borderColor ?? TANGO_THEME.foreground);
  const stroke = `.stroke(${color}, style: ${lineStrokeStyle(s)})`;
  const segment = `${pathExpr(node.shapePoints ?? [], false)}\n  ${stroke}`;
  if (!node.arrowHead) {
    return withModifiers(segment, [shadowModifier(s), frameModifier(node)]);
  }
  // Arrowhead strokes solid even on dashed lines (a dashed V reads as noise).
  const headStroke = `.stroke(${color}, style: StrokeStyle(lineWidth: ${fmt(s.borderWidth ?? 2)}, lineCap: .round, lineJoin: .round))`;
  const head = `${pathExpr(node.arrowHead, false)}\n  ${headStroke}`;
  const base = `ZStack(alignment: .topLeading) {\n${indent(segment, 1)}\n${indent(head, 1)}\n}`;
  return withModifiers(base, [shadowModifier(s), frameModifier(node)]);
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
    case 'ellipse':
      expr = emitEllipse(node);
      break;
    case 'polygon':
      expr = emitPolygon(node);
      break;
    case 'line':
      expr = emitLine(node);
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

// ── body + file assembly ────────────────────────────────────────────────────

// Header marker of the RETIRED whole-file export paradigm (TangoGenerated/).
// Kept so the export step can still recognize and clean up old generated
// files; nothing emits it anymore.
export const GENERATED_MARKER = 'tango:generated';

/**
 * The interior of one screen's `var body` — what in-place export splices into
 * the user's View struct (linked screens) and emitScreenFile wraps for new
 * ones. Relative indentation only; the splicer re-bases it to the target
 * file's own indent style. Line 1 is the tango:body marker (see swiftScan).
 */
export function emitScreenBody(screen: ResolvedScreen): string {
  const nodes = screen.nodes.map(emitNode);
  const body =
    nodes.length === 0
      ? indent('EmptyView()', 1)
      : indent(chunkIntoGroups(nodes), 1);
  const bg = swiftColor(TANGO_THEME.background);
  return `${bodyMarkerLine(screen.id)}
ZStack(alignment: .topLeading) {
${body}
}
.frame(width: ${fmt(screen.frame.w)}, height: ${fmt(screen.frame.h)}, alignment: .topLeading)
.background(${bg})
.clipped()`;
}

/**
 * A complete new .swift file for a screen with no source tie. Created once at
 * the project's source root; from then on the screen is linked to it and
 * exports splice only the marked body — the file is the user's to extend
 * (wire it into navigation, add properties, …).
 */
export function emitScreenFile(screen: ResolvedScreen, typeName: string): string {
  return `// Created by tango from the design screen ${swiftStringLiteral(screen.title)}.
// The body below is design-managed (tango:body marker) and is regenerated by
// every Export & Run; the rest of this file is yours.

import SwiftUI

/// ${screen.title.replace(/\n/g, ' ')} — ${fmt(screen.frame.w)}×${fmt(screen.frame.h)}
struct ${typeName}: View {
  var body: some View {
${indent(emitScreenBody(screen), 2)}
  }
}

#Preview {
  ${typeName}()
}
`;
}
