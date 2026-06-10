// Deterministic design-system pre-pass for the fast import: regex/JSON
// extraction over the workspace's Swift sources and asset catalogs — color
// tokens, type ramp, spacing/radius histograms, icon usage, and reusable-
// component candidates. No LLM, no AST: lightweight line heuristics that run
// in milliseconds before the import loop starts. The results seed
// `UISpec.designSystem` directly (tokens are deterministic facts) and the
// kickoff message (component candidates are *suggestions* — deciding what's a
// reusable component stays agent-mediated, per the hybrid translation rule).
//
// Pure functions take `{relPath, content}` pairs so tests script sources
// inline; only `runDesignScan` touches the filesystem. Runs in the
// route-handler module graph (called from uiImport) — keep it bridge-free.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { sfSymbolToLucide } from '@/lib/lucideToSfSymbol';
import type {
  UIColorToken,
  UIDesignSystem,
  UITextStyleToken,
} from '@/lib/uiMockProtocol';

export type SwiftSourceFile = { relPath: string; content: string };

export type ComponentCandidate = {
  // The `struct X: View` type name.
  name: string;
  // Workspace-relative file declaring it.
  declaredIn: string;
  // How many OTHER files reference the name (word-boundary). 2+ usually
  // means a shared component; 0 means screen-or-dead-code.
  referencedByFiles: number;
};

export type DesignScanResult = {
  designSystem: UIDesignSystem;
  componentCandidates: ComponentCandidate[];
};

// ── caps (keep the kickoff block and the stored tokens small) ───────────────
const MAX_COLORS = 16;
const MAX_TYPE_STYLES = 12;
const MAX_SPACING = 8;
const MAX_RADII = 6;
const MAX_ICONS = 24;
const MAX_CANDIDATES = 20;
const MAX_NOTES = 6;
const MAX_COLOR_ASSETS = 200;

// ── color helpers ────────────────────────────────────────────────────────────

function channelToByte(raw: string): number | null {
  const v = raw.trim();
  if (v === '') return null;
  if (/^0x[0-9a-f]+$/i.test(v)) {
    const n = parseInt(v, 16);
    return n >= 0 && n <= 255 ? n : null;
  }
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) return null;
  // Xcode writes floats ("1.000", "0.502") or 0-255 ints ("128"). Values ≤ 1
  // without being clearly integral bytes are fractions; "1" reads as 1.0.
  // A dotted value above 1 is malformed, not a byte.
  if (v.includes('.')) return n <= 1 ? Math.round(n * 255) : null;
  if (n <= 1) return Math.round(n * 255);
  return n <= 255 ? Math.round(n) : null;
}

function byteToHex(n: number): string {
  return Math.max(0, Math.min(255, n)).toString(16).padStart(2, '0').toUpperCase();
}

export function rgbaToHex(r: number, g: number, b: number, a = 1): string {
  const base = `#${byteToHex(r)}${byteToHex(g)}${byteToHex(b)}`;
  return a >= 1 ? base : `${base}${byteToHex(Math.round(a * 255))}`;
}

function floatChannelsToHex(
  r: string,
  g: string,
  b: string,
  a?: string,
): string | null {
  const rr = Number(r);
  const gg = Number(g);
  const bb = Number(b);
  const aa = a === undefined ? 1 : Number(a);
  if (![rr, gg, bb, aa].every((v) => Number.isFinite(v) && v >= 0 && v <= 1)) {
    return null;
  }
  return rgbaToHex(
    Math.round(rr * 255),
    Math.round(gg * 255),
    Math.round(bb * 255),
    aa,
  );
}

// Parse one *.colorset/Contents.json. Uses the first "any"/light appearance
// entry. Returns null on anything malformed — asset catalogs are
// user-authored JSON, never trust the shape.
export function parseColorsetJson(
  name: string,
  raw: string,
): UIColorToken | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  const colors = (parsed as { colors?: unknown })?.colors;
  if (!Array.isArray(colors)) return null;
  type Entry = {
    appearances?: unknown[];
    color?: { components?: Record<string, unknown> };
  };
  const entry =
    (colors as Entry[]).find((c) => !c?.appearances?.length && c?.color) ??
    (colors as Entry[]).find((c) => c?.color);
  const comps = entry?.color?.components;
  if (!comps) return null;
  const r = channelToByte(String(comps.red ?? ''));
  const g = channelToByte(String(comps.green ?? ''));
  const b = channelToByte(String(comps.blue ?? ''));
  const aRaw = comps.alpha === undefined ? '1' : String(comps.alpha);
  const aByte = channelToByte(aRaw);
  if (r == null || g == null || b == null || aByte == null) return null;
  return { name, value: rgbaToHex(r, g, b, aByte / 255) };
}

// ── per-file Swift extraction ────────────────────────────────────────────────

type Counter = Map<string, number>;

function bump(map: Counter, key: string, by = 1): void {
  map.set(key, (map.get(key) ?? 0) + by);
}

export type SwiftFileScan = {
  // hex → count for literal colors; named asset colors counted separately.
  colorHexes: Counter;
  // hex → declared identifier (static let brand = Color(...)).
  colorNames: Map<string, string>;
  // Color("AssetName") usages: asset name → count.
  namedColorRefs: Counter;
  // serialized text-style key → count (see typeStyleKey).
  typeStyles: Counter;
  spacings: Counter;
  radii: Counter;
  // SF symbol name → count.
  sfSymbols: Counter;
  // ".shadow(radius: 8, x: 0, y: 2)" signatures → count.
  shadows: Counter;
  // `struct X: View` declarations in this file.
  viewStructs: string[];
};

const FONT_WEIGHTS: Record<string, number> = {
  ultraLight: 100,
  thin: 200,
  light: 300,
  regular: 400,
  medium: 500,
  semibold: 600,
  bold: 700,
  heavy: 800,
  black: 900,
};

// Built-in SwiftUI text styles → approximate pt size/weight (iOS large
// default). Names stay the SwiftUI style names so agents recognize them.
const BUILTIN_TEXT_STYLES: Record<string, { size: number; weight?: number }> = {
  largeTitle: { size: 34, weight: 700 },
  title: { size: 28 },
  title2: { size: 22 },
  title3: { size: 20 },
  headline: { size: 17, weight: 600 },
  body: { size: 17 },
  callout: { size: 16 },
  subheadline: { size: 15 },
  footnote: { size: 13 },
  caption: { size: 12 },
  caption2: { size: 11 },
};

function typeStyleKey(
  name: string,
  size: number,
  weight?: number,
  family?: string,
): string {
  return JSON.stringify([name, size, weight ?? null, family ?? null]);
}

function parseTypeStyleKey(key: string): UITextStyleToken {
  const [name, size, weight, family] = JSON.parse(key) as [
    string,
    number,
    number | null,
    string | null,
  ];
  return {
    name,
    size,
    ...(weight != null ? { weight } : {}),
    ...(family != null ? { family } : {}),
  };
}

const NUM = String.raw`(\d+(?:\.\d+)?)`;

// Color(red: r, green: g, blue: b[, opacity|alpha: a]) — Color or UIColor,
// with an optional leading colorspace arg (.sRGB, …). Channels are 0–1.
const RGB_COLOR_RE = new RegExp(
  String.raw`(?:UI)?Color\(\s*(?:\.\w+\s*,\s*)?red:\s*${NUM}\s*,\s*green:\s*${NUM}\s*,\s*blue:\s*${NUM}\s*(?:,\s*(?:opacity|alpha):\s*${NUM}\s*)?\)`,
  'g',
);
const COLOR_LITERAL_RE = new RegExp(
  String.raw`#colorLiteral\(\s*red:\s*${NUM}\s*,\s*green:\s*${NUM}\s*,\s*blue:\s*${NUM}\s*,\s*alpha:\s*${NUM}\s*\)`,
  'g',
);
// Color(hex: 0xRRGGBB) / Color(hex: "#RRGGBB") — common project extension.
const HEX_COLOR_RE =
  /(?:UI)?Color\(\s*hex:\s*(?:0x([0-9a-fA-F]{6,8})|"#?([0-9a-fA-F]{6,8})")\s*\)/g;
// Color("AssetName") — named catalog color.
const NAMED_COLOR_RE = /\bColor\(\s*"([^"]+)"\s*\)/g;
// `static let brand = Color(...)`-style declaration on the same line.
const DECL_RE = /\b(?:let|var)\s+(\w+)(?:\s*:\s*Color)?\s*=\s*(?:UI)?Color\(/;

const SYSTEM_FONT_RE = new RegExp(
  String.raw`\.font\(\s*\.system\(\s*size:\s*${NUM}\s*(?:,\s*weight:\s*\.(\w+))?`,
  'g',
);
const BUILTIN_FONT_RE = /\.font\(\s*\.(\w+)\s*\)/g;
const CUSTOM_FONT_RE = new RegExp(
  String.raw`\.custom\(\s*"([^"]+)"\s*,\s*(?:size:\s*)?${NUM}`,
  'g',
);

const SPACING_RE = new RegExp(String.raw`\bspacing:\s*${NUM}`, 'g');
const PADDING_RE = new RegExp(
  String.raw`\.padding\(\s*(?:\[?[.\w,\s]*\]?\s*,\s*)?${NUM}\s*\)`,
  'g',
);
const RADIUS_RE = new RegExp(String.raw`\bcornerRadius:?\s*\(?\s*${NUM}`, 'g');
const SF_SYMBOL_RE = /\bsystemName:\s*"([^"]+)"/g;
// The color arg can carry parens (.black.opacity(0.05)) but not a top-level
// comma — match anything up to the comma that precedes `radius:`.
const SHADOW_RE =
  /\.shadow\(\s*(?:color:\s*[^,]+,\s*)?radius:\s*(\d+(?:\.\d+)?)\s*(?:,\s*x:\s*(-?\d+(?:\.\d+)?)\s*)?(?:,\s*y:\s*(-?\d+(?:\.\d+)?)\s*)?\)/g;
const VIEW_STRUCT_RE = /\bstruct\s+(\w+)(?:<[^>]*>)?\s*:\s*(?:\w+\s*,\s*)*View\b/g;

// Strip comments so commented-out code can't contribute tokens or struct
// declarations. Line-based: `state.inBlock` carries /* */ state across lines.
export function stripSwiftComments(
  line: string,
  state: { inBlock: boolean },
): string {
  let out = '';
  let i = 0;
  while (i < line.length) {
    if (state.inBlock) {
      const close = line.indexOf('*/', i);
      if (close === -1) return out;
      state.inBlock = false;
      i = close + 2;
      continue;
    }
    const lineComment = line.indexOf('//', i);
    const blockOpen = line.indexOf('/*', i);
    if (blockOpen !== -1 && (lineComment === -1 || blockOpen < lineComment)) {
      out += line.slice(i, blockOpen);
      state.inBlock = true;
      i = blockOpen + 2;
      continue;
    }
    if (lineComment !== -1) {
      out += line.slice(i, lineComment);
      return out;
    }
    out += line.slice(i);
    return out;
  }
  return out;
}

export function scanSwiftSource(content: string): SwiftFileScan {
  const scan: SwiftFileScan = {
    colorHexes: new Map(),
    colorNames: new Map(),
    namedColorRefs: new Map(),
    typeStyles: new Map(),
    spacings: new Map(),
    radii: new Map(),
    sfSymbols: new Map(),
    shadows: new Map(),
    viewStructs: [],
  };

  const commentState = { inBlock: false };
  for (const rawLine of content.split('\n')) {
    const line = stripSwiftComments(rawLine, commentState);
    if (!line.trim()) continue;

    // A `let x = Color(...)` declaration names only the color whose
    // initializer sits at the decl's own `Color(` — not whichever color
    // literal happens to match first on the line.
    const declMatch = DECL_RE.exec(line);
    const decl = declMatch
      ? {
          name: declMatch[1],
          initStart:
            declMatch.index +
            declMatch[0].length -
            (declMatch[0].endsWith('UIColor(') ? 'UIColor(' : 'Color(').length,
        }
      : null;

    for (const m of line.matchAll(RGB_COLOR_RE)) {
      const hex = floatChannelsToHex(m[1], m[2], m[3], m[4]);
      if (!hex) continue;
      bump(scan.colorHexes, hex);
      if (decl && m.index === decl.initStart) {
        if (!scan.colorNames.has(hex)) scan.colorNames.set(hex, decl.name);
      }
    }
    for (const m of line.matchAll(COLOR_LITERAL_RE)) {
      const hex = floatChannelsToHex(m[1], m[2], m[3], m[4]);
      if (hex) bump(scan.colorHexes, hex);
    }
    for (const m of line.matchAll(HEX_COLOR_RE)) {
      const raw = (m[1] ?? m[2]).toUpperCase();
      // 8-digit literals are ambiguous (RRGGBBAA vs AARRGGBB project
      // extensions). A trailing FF reads safely as opaque RRGGBB; anything
      // else is skipped — a missing token beats a confidently-wrong one.
      if (raw.length === 8 && !raw.endsWith('FF')) continue;
      const hex = `#${raw.length === 8 ? raw.slice(0, 6) : raw}`;
      bump(scan.colorHexes, hex);
      if (decl && m.index === decl.initStart) {
        if (!scan.colorNames.has(hex)) scan.colorNames.set(hex, decl.name);
      }
    }
    for (const m of line.matchAll(NAMED_COLOR_RE)) {
      bump(scan.namedColorRefs, m[1]);
    }

    for (const m of line.matchAll(SYSTEM_FONT_RE)) {
      const size = Number(m[1]);
      const weight = m[2] ? FONT_WEIGHTS[m[2]] : undefined;
      const name = `system-${size}${m[2] ? `-${m[2]}` : ''}`;
      bump(scan.typeStyles, typeStyleKey(name, size, weight));
    }
    for (const m of line.matchAll(BUILTIN_FONT_RE)) {
      const style = BUILTIN_TEXT_STYLES[m[1]];
      if (!style) continue;
      bump(scan.typeStyles, typeStyleKey(m[1], style.size, style.weight));
    }
    for (const m of line.matchAll(CUSTOM_FONT_RE)) {
      bump(
        scan.typeStyles,
        typeStyleKey(`${m[1]}-${Number(m[2])}`, Number(m[2]), undefined, m[1]),
      );
    }

    // Key on the normalized number so `8` and `8.0` merge their counts.
    for (const m of line.matchAll(SPACING_RE)) {
      bump(scan.spacings, String(Number(m[1])));
    }
    for (const m of line.matchAll(PADDING_RE)) {
      bump(scan.spacings, String(Number(m[1])));
    }
    for (const m of line.matchAll(RADIUS_RE)) {
      bump(scan.radii, String(Number(m[1])));
    }
    for (const m of line.matchAll(SF_SYMBOL_RE)) bump(scan.sfSymbols, m[1]);
    for (const m of line.matchAll(SHADOW_RE)) {
      const sig = `radius ${m[1]}${m[2] !== undefined ? `, x ${m[2]}` : ''}${m[3] !== undefined ? `, y ${m[3]}` : ''}`;
      bump(scan.shadows, sig);
    }
    for (const m of line.matchAll(VIEW_STRUCT_RE)) {
      scan.viewStructs.push(m[1]);
    }
  }
  return scan;
}

// ── aggregation ──────────────────────────────────────────────────────────────

function topEntries(map: Counter, max: number): Array<[string, number]> {
  return [...map.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, max);
}

function mergeCounter(into: Counter, from: Counter): void {
  for (const [k, v] of from) bump(into, k, v);
}

// Aggregate per-file scans + asset-catalog colors into a UIDesignSystem and
// the component-candidate list. Deterministic: sorted by count desc, then
// name asc, capped.
export function aggregateDesignScan(
  files: Array<{ relPath: string; scan: SwiftFileScan; content: string }>,
  assetColors: UIColorToken[],
): DesignScanResult {
  const colorHexes: Counter = new Map();
  const colorNames = new Map<string, string>();
  const namedColorRefs: Counter = new Map();
  const typeStyles: Counter = new Map();
  const spacings: Counter = new Map();
  const radii: Counter = new Map();
  const sfSymbols: Counter = new Map();
  const shadows: Counter = new Map();

  for (const f of files) {
    mergeCounter(colorHexes, f.scan.colorHexes);
    mergeCounter(namedColorRefs, f.scan.namedColorRefs);
    mergeCounter(typeStyles, f.scan.typeStyles);
    mergeCounter(spacings, f.scan.spacings);
    mergeCounter(radii, f.scan.radii);
    mergeCounter(sfSymbols, f.scan.sfSymbols);
    mergeCounter(shadows, f.scan.shadows);
    for (const [hex, name] of f.scan.colorNames) {
      if (!colorNames.has(hex)) colorNames.set(hex, name);
    }
  }

  // Colors: asset-catalog tokens first (they're named, definitional), with
  // usage counts from Color("Name") refs; then literal colors by frequency.
  // MAX_COLORS caps the COMBINED list — a catalog-heavy app keeps its
  // most-referenced colorsets, not all 200.
  const colors: UIColorToken[] = [];
  const seenColorKeys = new Set<string>();
  for (const token of assetColors.slice(0, MAX_COLOR_ASSETS)) {
    if (seenColorKeys.has(token.name)) continue;
    seenColorKeys.add(token.name);
    const count = namedColorRefs.get(token.name);
    colors.push({ ...token, ...(count !== undefined ? { count } : {}) });
  }
  colors.sort((a, b) => (b.count ?? 0) - (a.count ?? 0) || a.name.localeCompare(b.name));
  colors.splice(MAX_COLORS);
  for (const [hex, count] of topEntries(colorHexes, MAX_COLORS)) {
    if (colors.length >= MAX_COLORS) break;
    const name = colorNames.get(hex) ?? hex.toLowerCase();
    if (seenColorKeys.has(name)) continue;
    seenColorKeys.add(name);
    colors.push({ name, value: hex, count });
  }

  const typography: UITextStyleToken[] = topEntries(
    typeStyles,
    MAX_TYPE_STYLES,
  ).map(([key, count]) => ({ ...parseTypeStyleKey(key), count }));

  const spacingVals = topEntries(spacings, MAX_SPACING).map(([v]) => Number(v));
  const radiiVals = topEntries(radii, MAX_RADII).map(([v]) => Number(v));

  const icons: string[] = [];
  const seenIcons = new Set<string>();
  for (const [sf] of topEntries(sfSymbols, sfSymbols.size)) {
    const lucide = sfSymbolToLucide(sf);
    if (!lucide || seenIcons.has(lucide)) continue;
    seenIcons.add(lucide);
    icons.push(lucide);
    if (icons.length >= MAX_ICONS) break;
  }

  const notes = topEntries(shadows, 3).map(
    ([sig, count]) => `shadow ${sig} (×${count})`,
  );

  const designSystem: UIDesignSystem = {
    ...(colors.length ? { colors } : {}),
    ...(typography.length ? { typography } : {}),
    ...(spacingVals.length ? { spacing: spacingVals } : {}),
    ...(radiiVals.length ? { radii: radiiVals } : {}),
    ...(icons.length ? { icons } : {}),
    ...(notes.length ? { notes: notes.slice(0, MAX_NOTES) } : {}),
  };

  // Component candidates: every `struct X: View`, scored by how many OTHER
  // files mention the name. The agent decides which are real components.
  const declarations = new Map<string, string>(); // name → declaring file
  for (const f of files) {
    for (const name of f.scan.viewStructs) {
      if (!declarations.has(name)) declarations.set(name, f.relPath);
    }
  }
  // Count references against a comment/string-stripped corpus and require a
  // call-site shape (`Name(`, `Name {`, `Name.`, `Name<`) — otherwise screen
  // structs with UI-label names (Settings, Profile, Home) rack up "refs"
  // from Text("Settings") string literals. Stripped once per file: this loop
  // is the scan's dominant CPU term.
  const referenceCorpus = files.map((f) => ({
    relPath: f.relPath,
    text: f.content
      .replace(/\/\*[\s\S]*?\*\//g, ' ')
      .replace(/\/\/.*$/gm, ' ')
      .replace(/"(?:\\.|[^"\\\n])*"/g, '""'),
  }));
  const componentCandidates: ComponentCandidate[] = [];
  for (const [name, declaredIn] of declarations) {
    const re = new RegExp(String.raw`\b${name}\s*[({.<]`);
    let referencedByFiles = 0;
    for (const f of referenceCorpus) {
      if (f.relPath === declaredIn) continue;
      if (re.test(f.text)) referencedByFiles += 1;
    }
    componentCandidates.push({ name, declaredIn, referencedByFiles });
  }
  componentCandidates.sort(
    (a, b) =>
      b.referencedByFiles - a.referencedByFiles || a.name.localeCompare(b.name),
  );
  return {
    designSystem,
    componentCandidates: componentCandidates.slice(0, MAX_CANDIDATES),
  };
}

// Compact kickoff-message block describing what the scanner found. Keep it
// dense — it rides every import kickoff (and the prompt cache only covers
// the system prompt, not this).
export function designScanKickoffBlock(result: DesignScanResult): string {
  const ds = result.designSystem;
  const tokenLines: string[] = [];
  if (ds.colors?.length) {
    tokenLines.push(
      `Colors: ${ds.colors
        .map((c) => `${c.name} ${c.value}${c.count ? ` ×${c.count}` : ''}`)
        .join(', ')}`,
    );
  }
  if (ds.typography?.length) {
    tokenLines.push(
      `Type: ${ds.typography
        .map((t) => `${t.name} (${t.size}pt${t.weight ? ` w${t.weight}` : ''}) ×${t.count ?? 1}`)
        .join(', ')}`,
    );
  }
  if (ds.spacing?.length) tokenLines.push(`Spacing: ${ds.spacing.join(', ')}`);
  if (ds.radii?.length) tokenLines.push(`Radii: ${ds.radii.join(', ')}`);
  if (ds.icons?.length) {
    tokenLines.push(`Icons (lucide): ${ds.icons.join(', ')}`);
  }
  if (ds.notes?.length) tokenLines.push(`Notes: ${ds.notes.join('; ')}`);
  const candidates = result.componentCandidates.filter(
    (c) => c.referencedByFiles > 0,
  );
  const parts: string[] = [];
  if (tokenLines.length) {
    // The "stored" claim must track uiImport's stamping guard: tokens land on
    // spec.designSystem exactly when the scan found any.
    parts.push(
      `Design-system scan of the sources (deterministic, pre-extracted — already stored on spec.designSystem):\n${tokenLines.map((l) => `- ${l}`).join('\n')}`,
    );
  }
  if (candidates.length) {
    parts.push(
      `Reusable view struct candidates (suggestions only, NOT stored — emit_component the ones that are real components): ${candidates
        .map((c) => `${c.name} (${c.declaredIn}, ${c.referencedByFiles})`)
        .join(', ')}`,
    );
  }
  return parts.join('\n');
}

// ── filesystem orchestration ─────────────────────────────────────────────────

// Same exclusions as the Swift walk in uiImport (kept local — importing them
// from uiImport would create a module cycle).
const SKIP_DIRS = new Set([
  'Pods',
  'DerivedData',
  'build',
  '.build',
  '.swiftpm',
  '.tango',
  '.git',
  'node_modules',
  'Preview Content',
]);
const MAX_ASSET_SCAN_DEPTH = 8;

// Find `*.colorset/Contents.json` files under any `*.xcassets` catalog and
// parse them into named tokens. Best-effort: unreadable/malformed entries
// are skipped.
export async function findAssetColors(
  workspace: string,
  readFile: (abs: string) => Promise<string> = (p) => fs.readFile(p, 'utf8'),
): Promise<UIColorToken[]> {
  const out: UIColorToken[] = [];
  async function walk(dir: string, depth: number, inCatalog: boolean) {
    if (depth > MAX_ASSET_SCAN_DEPTH || out.length >= MAX_COLOR_ASSETS) return;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (out.length >= MAX_COLOR_ASSETS) return;
      if (!entry.isDirectory()) continue;
      if (SKIP_DIRS.has(entry.name)) continue;
      const abs = path.join(dir, entry.name);
      if (inCatalog && entry.name.endsWith('.colorset')) {
        const name = entry.name.slice(0, -'.colorset'.length);
        try {
          const raw = await readFile(path.join(abs, 'Contents.json'));
          const token = parseColorsetJson(name, raw);
          if (token) out.push(token);
        } catch {
          // no Contents.json — skip
        }
        continue;
      }
      await walk(abs, depth + 1, inCatalog || entry.name.endsWith('.xcassets'));
    }
  }
  await walk(workspace, 0, false);
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

// Read every listed Swift source once and aggregate. ~200 files capped by the
// caller's scan; on the order of 100-200ms at the cap — noise next to the
// LLM loop's tens of seconds.
export async function runDesignScan(
  workspace: string,
  swiftFiles: Array<{ relPath: string; generated: boolean }>,
  readFile: (abs: string) => Promise<string> = (p) => fs.readFile(p, 'utf8'),
): Promise<DesignScanResult> {
  const files: Array<{ relPath: string; scan: SwiftFileScan; content: string }> =
    [];
  for (const f of swiftFiles) {
    // TangoGenerated exports are tango's own output — their literals would
    // double-count the design's existing values.
    if (f.generated) continue;
    let content: string;
    try {
      content = await readFile(path.join(workspace, f.relPath));
    } catch {
      continue;
    }
    files.push({ relPath: f.relPath, scan: scanSwiftSource(content), content });
  }
  const assetColors = await findAssetColors(workspace, readFile);
  return aggregateDesignScan(files, assetColors);
}
