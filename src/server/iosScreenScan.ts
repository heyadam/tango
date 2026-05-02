// Server-side scanner for `tango-ios-map` — turns a workspace's Swift /
// Storyboard sources into the {screens, edges, entries} graph that the
// `set_screen_flow` MCP tool renders. Lifts the regex+walk logic that used
// to live in the `tango-ios-map` SKILL body so terminal-Claude doesn't have
// to read every file in-context.
//
// Pure parsers are exported for unit testing without touching the
// filesystem; the disk-walking entry point is `scanIosScreens`.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { registerHook } from './serverHooks';

export type ScreenKind = 'swiftui' | 'uikit' | 'storyboard';
export type EdgeKind = 'push' | 'sheet' | 'cover' | 'present' | 'segue' | 'tab';

export type ScannedScreen = {
  id: string;
  name: string;
  kind: ScreenKind;
  filePath?: string;
  summary?: string;
  isEntry?: boolean;
};

export type ScannedEdge = {
  from: string;
  to: string;
  kind: EdgeKind;
  label?: string;
};

export type ScanResult = {
  screens: ScannedScreen[];
  edges: ScannedEdge[];
  scannedFiles: number;
  cachedFiles: number;
  skippedDirs: number;
};

// --- Skip set (mirrors the `tango-ios-map` skill's § 3) -----------------

const SKIP_DIR_NAMES = new Set([
  'Pods',
  '.build',
  'DerivedData',
  '.swiftpm',
  'build',
  '.git',
  'node_modules',
  'Preview Content',
]);

const SKIP_DIR_SUFFIXES = ['.xcassets', '.xcdatamodel', '.xcdatamodeld'];

const SKIP_FILE_PATTERNS: RegExp[] = [
  /Tests\.swift$/,
  /UITests\.swift$/,
  /Previews\.swift$/,
];

const SKIP_PATH_FRAGMENTS = ['/Tests/', '/UITests/'];

export function shouldSkipDir(name: string): boolean {
  if (SKIP_DIR_NAMES.has(name)) return true;
  for (const suf of SKIP_DIR_SUFFIXES) {
    if (name.endsWith(suf)) return true;
  }
  return false;
}

export function shouldSkipFile(absPath: string): boolean {
  for (const re of SKIP_FILE_PATTERNS) {
    if (re.test(absPath)) return true;
  }
  for (const frag of SKIP_PATH_FRAGMENTS) {
    if (absPath.includes(frag)) return true;
  }
  return false;
}

// --- Regex constants (lifted from `tango-ios-map` § 4 + § 6) ------------

// Top-level (column-0) `struct Foo: ...View...`. Tolerant of access
// modifiers, generics, attached attributes — but anchored at the line start
// so nested inner views don't match.
export const SWIFTUI_VIEW_RE =
  /^(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|@\w+(?:\([^)]*\))?\s+)*struct\s+(\w+)\s*(?:<[^>]*>)?\s*:[^{]*\bView\b[^{]*\{/gm;

// Top-level UIViewController class. Captures the type name; conformance must
// end in `ViewController` or `VC` (case-sensitive — Swift convention).
export const UIKIT_VC_RE =
  /^(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+)*class\s+(\w+)\s*(?:<[^>]*>)?\s*:[^{]*?\b\w*(?:ViewController|VC)\b[^{]*\{/gm;

// SwiftUI navigation patterns. Each captures the destination type name as
// `\1`. Capitalize the captured name (`[A-Z]\w*`) so a helper-call sitting
// between the closure brace and the destination — `.sheet { let x = …;
// RealDestination() }` — doesn't false-match the helper. Multi-line tolerant
// via `[\s\S]`. The `[A-Z]` guard is the same convention `parseSwiftEdges`
// uses when filtering captured names down to type identifiers.
const NAV_LINK_RE = /NavigationLink\s*\(\s*destination:\s*([A-Z]\w*)\s*\(/g;
const NAV_DESTINATION_RE =
  /\.navigationDestination\s*\([^)]*\)\s*\{[\s\S]*?\b([A-Z]\w*)\s*\(/g;
const SHEET_RE = /\.sheet\s*\([^)]*\)\s*\{[\s\S]*?\b([A-Z]\w*)\s*\(/g;
const COVER_RE = /\.fullScreenCover\s*\([^)]*\)\s*\{[\s\S]*?\b([A-Z]\w*)\s*\(/g;
const PUSH_VC_RE = /\bpushViewController\s*\(\s*([A-Z]\w*)\s*\(/g;
const PRESENT_RE = /\bpresent\s*\(\s*([A-Z]\w*)\s*\(/g;

// TabView body — capture the inner block, then re-scan for child View
// instantiations. The block regex is greedy-bounded by the first `}` after
// the opening `{`, which truncates on nested-modifier blocks (`HomeView()
// .sheet { … }` inside the TabView). Acceptable trade-off — TabView children
// are typically simple `Foo()` calls; if someone inlines a sheet inside a
// tab, the second tab is missed but that's better than over-capturing every
// PascalCase call site downstream.
const TAB_VIEW_BLOCK_RE = /TabView\s*(?:\([^)]*\))?\s*\{([\s\S]*?)\}/g;
const TAB_CHILD_RE = /\b([A-Z]\w*)\s*\(/g;
// Common false positives — SwiftUI value types that look like views but
// aren't navigation destinations. Filter these out at the scanner so they
// never reach `screenFlowDiagnostics.danglingEdges`.
const NON_DESTINATION_TYPES = new Set([
  'Color',
  'Image',
  'EmptyView',
  'Text',
  'Spacer',
  'Divider',
  'Group',
  'AnyView',
  'Label',
]);

// Storyboard. Match the full opening-tag body and sub-extract attributes —
// optional groups in fixed order make the regex sensitive to attribute
// ordering, and Xcode emits `id` first in real `.storyboard` files which
// silently dropped the `customClass` capture. Same lesson as the segue
// pattern below: tag-body match + per-attribute regex is the robust shape.
const STORYBOARD_VC_TAG_RE = /<viewController\b([^>]*?)\/?>/g;
const STORYBOARD_VC_CUSTOM_CLASS_RE = /\bcustomClass="(\w+)"/;
const STORYBOARD_VC_ID_RE = /\bid="([\w-]+)"/;
const STORYBOARD_VC_INITIAL_RE = /\bisInitialViewController="YES"/;
const STORYBOARD_SEGUE_TAG_RE = /<segue\b([^>]*?)\/?>/g;
const SEGUE_DEST_RE = /\bdestination="([\w-]+)"/;
const SEGUE_KIND_RE = /\bkind="(\w+)"/;

// Entry detection
const APP_DELEGATE_ROOT_RE =
  /window\??\.rootViewController\s*=\s*(\w+)\s*\(/g;
const WINDOW_GROUP_RE = /WindowGroup\s*(?:\([^)]*\))?\s*\{\s*(\w+)\s*\(/g;
const MAIN_ATTR_RE = /@main\b/;

// First-Text-literal summary: cheap inference for the `summary` field.
const FIRST_TEXT_LITERAL_RE = /\bText\s*\(\s*"([^"\\]{1,118})"\s*\)/;

// --- Pure parsers --------------------------------------------------------

export function parseSwiftUIScreens(
  content: string,
  filePath: string | undefined,
  includeSummaries: boolean,
): ScannedScreen[] {
  const screens: ScannedScreen[] = [];
  const seen = new Set<string>();
  for (const m of content.matchAll(SWIFTUI_VIEW_RE)) {
    const name = m[1];
    if (!name || seen.has(name)) continue;
    seen.add(name);
    const screen: ScannedScreen = {
      id: name,
      name,
      kind: 'swiftui',
      filePath,
    };
    if (includeSummaries) {
      const summary = inferSummaryFromBody(content, m.index ?? 0);
      if (summary) screen.summary = summary;
    }
    screens.push(screen);
  }
  return screens;
}

export function parseUIKitScreens(
  content: string,
  filePath: string | undefined,
): ScannedScreen[] {
  const screens: ScannedScreen[] = [];
  const seen = new Set<string>();
  for (const m of content.matchAll(UIKIT_VC_RE)) {
    const name = m[1];
    if (!name || seen.has(name)) continue;
    seen.add(name);
    screens.push({ id: name, name, kind: 'uikit', filePath });
  }
  return screens;
}

export function parseStoryboardScreens(
  content: string,
  filePath: string | undefined,
): ScannedScreen[] {
  const screens: ScannedScreen[] = [];
  const seen = new Set<string>();
  for (const m of content.matchAll(STORYBOARD_VC_TAG_RE)) {
    const body = m[1] ?? '';
    const customClass = STORYBOARD_VC_CUSTOM_CLASS_RE.exec(body)?.[1];
    const id = STORYBOARD_VC_ID_RE.exec(body)?.[1];
    const stableId = customClass ?? id;
    if (!stableId || seen.has(stableId)) continue;
    seen.add(stableId);
    screens.push({
      id: stableId,
      name: customClass ?? humanizeStoryboardId(id ?? stableId),
      kind: 'storyboard',
      filePath,
    });
  }
  return screens;
}

function humanizeStoryboardId(id: string): string {
  // "log-in-view-controller" → "Log In View Controller"
  return id
    .replace(/[-_]+/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim();
}

// Scan a content blob for outgoing navigation edges. The `from` is set by the
// caller (the screen whose file is being scanned) — Swift navigation edges
// originate from whichever file declared them, not from the destination type.
export function parseSwiftEdges(content: string, from: string): ScannedEdge[] {
  const edges: ScannedEdge[] = [];
  const seen = new Set<string>();

  const push = (toName: string, kind: EdgeKind) => {
    if (!toName || toName === from) return;
    // Capitalized type-name only — heuristic to avoid matching variable names.
    if (!/^[A-Z]/.test(toName)) return;
    // Skip stock SwiftUI value types that happen to be PascalCase but are
    // never navigation destinations. Cuts noise in TabView blocks where
    // `Color(.red)` / `Image("…")` / `EmptyView()` would otherwise become
    // dangling-edge diagnostics.
    if (NON_DESTINATION_TYPES.has(toName)) return;
    const key = `${toName}|${kind}`;
    if (seen.has(key)) return;
    seen.add(key);
    edges.push({ from, to: toName, kind });
  };

  for (const m of content.matchAll(NAV_LINK_RE)) push(m[1], 'push');
  for (const m of content.matchAll(NAV_DESTINATION_RE)) push(m[1], 'push');
  for (const m of content.matchAll(SHEET_RE)) push(m[1], 'sheet');
  for (const m of content.matchAll(COVER_RE)) push(m[1], 'cover');
  for (const m of content.matchAll(PUSH_VC_RE)) push(m[1], 'push');
  for (const m of content.matchAll(PRESENT_RE)) push(m[1], 'present');

  for (const m of content.matchAll(TAB_VIEW_BLOCK_RE)) {
    const block = m[1] ?? '';
    for (const child of block.matchAll(TAB_CHILD_RE)) {
      push(child[1], 'tab');
    }
  }

  return edges;
}

// Storyboard segue translation:
//   kind="show" / "push"            → push
//   kind="modal" / "presentModally" → sheet
//   anything else                    → segue
export function parseStoryboardEdges(
  content: string,
  fromId: string,
): ScannedEdge[] {
  const edges: ScannedEdge[] = [];
  for (const m of content.matchAll(STORYBOARD_SEGUE_TAG_RE)) {
    const body = m[1] ?? '';
    const destMatch = SEGUE_DEST_RE.exec(body);
    if (!destMatch) continue;
    const dest = destMatch[1];
    const kindAttr = SEGUE_KIND_RE.exec(body)?.[1];
    let kind: EdgeKind = 'segue';
    if (kindAttr === 'show' || kindAttr === 'push') kind = 'push';
    else if (kindAttr === 'modal' || kindAttr === 'presentModally') kind = 'sheet';
    edges.push({ from: fromId, to: dest, kind });
  }
  return edges;
}

// Best-effort: read the body window after `match.index` and pull the first
// `Text("…")` literal as a one-line summary. Returns null if no Text in the
// next ~2000 chars (most View bodies fit comfortably).
function inferSummaryFromBody(content: string, startIdx: number): string | null {
  const window = content.slice(startIdx, startIdx + 2000);
  const m = FIRST_TEXT_LITERAL_RE.exec(window);
  if (!m) return null;
  const summary = m[1].trim();
  return summary.length > 0 ? summary : null;
}

// Collect entry-point screen ids from a content blob. Used by the caller's
// per-file scan; the caller unions across files and intersects with the
// final screen set.
export function detectEntryIds(content: string, kind: 'swift' | 'storyboard'): string[] {
  const ids: string[] = [];
  if (kind === 'swift') {
    if (MAIN_ATTR_RE.test(content)) {
      for (const m of content.matchAll(WINDOW_GROUP_RE)) {
        if (m[1]) ids.push(m[1]);
      }
    }
    for (const m of content.matchAll(APP_DELEGATE_ROOT_RE)) {
      if (m[1]) ids.push(m[1]);
    }
  } else {
    for (const m of content.matchAll(STORYBOARD_VC_TAG_RE)) {
      const body = m[1] ?? '';
      if (!STORYBOARD_VC_INITIAL_RE.test(body)) continue;
      const customClass = STORYBOARD_VC_CUSTOM_CLASS_RE.exec(body)?.[1];
      const id = STORYBOARD_VC_ID_RE.exec(body)?.[1];
      const stableId = customClass ?? id;
      if (stableId) ids.push(stableId);
    }
  }
  return ids;
}

// --- File walk + cache ---------------------------------------------------

type CacheEntry = {
  mtimeMs: number;
  screens: ScannedScreen[];
  edges: ScannedEdge[];
  entryIds: string[];
};

type FileCache = Map<string, CacheEntry>;

const CACHE_KEY = '__tangoIosScreenScanCache__';

function getCache(): { byPath: FileCache } {
  const g = globalThis as typeof globalThis & {
    [CACHE_KEY]?: { byPath: FileCache };
  };
  if (!g[CACHE_KEY]) g[CACHE_KEY] = { byPath: new Map() };
  return g[CACHE_KEY];
}

export function resetIosScreenScanCache(): void {
  getCache().byPath.clear();
}

// Test-only inspection seam — exposes the live cache size so coverage tests
// can assert eviction actually happens (vs. just checking the result list).
// Not part of the public API; do not call from feature code.
export function _iosScreenScanCacheSizeForTests(): number {
  return getCache().byPath.size;
}

// Wired into the workspace-switch hook chain via its own key so a switch
// wipes stale entries. Don't piggyback on `resetCanvas` — `registerHook`
// last-write-wins, and the canvas hook in canvasBridge.ts owns that key.
registerHook('resetIosScan', () => {
  resetIosScreenScanCache();
});

async function walkSwiftSources(
  rootDir: string,
): Promise<{ swift: string[]; storyboard: string[]; skippedDirs: number }> {
  const swift: string[] = [];
  const storyboard: string[] = [];
  let skippedDirs = 0;
  // realpath-keyed visited set so symlink loops don't recurse forever AND a
  // symlink pointing at a dir we already walked direct-path doesn't cause
  // double capture. We realpath every entered dir, not just symlinks.
  const visitedRealPaths = new Set<string>();
  const visitedRealFiles = new Set<string>();

  async function shouldEnterDir(full: string): Promise<boolean> {
    let real: string;
    try {
      real = await fs.realpath(full);
    } catch {
      return false;
    }
    if (visitedRealPaths.has(real)) return false;
    visitedRealPaths.add(real);
    return true;
  }

  async function shouldEmitFile(full: string): Promise<boolean> {
    let real: string;
    try {
      real = await fs.realpath(full);
    } catch {
      return false;
    }
    if (visitedRealFiles.has(real)) return false;
    visitedRealFiles.add(real);
    return true;
  }

  // Classify an entry, following symlinks to their real type. Returns null
  // for things we can't or shouldn't traverse (broken links, sockets, etc.).
  async function classify(
    full: string,
    entry: { isDirectory(): boolean; isFile(): boolean; isSymbolicLink(): boolean },
  ): Promise<'dir' | 'file' | null> {
    if (entry.isSymbolicLink()) {
      let stat;
      try {
        stat = await fs.stat(full); // follows symlinks
      } catch {
        return null;
      }
      if (stat.isDirectory()) return 'dir';
      if (stat.isFile()) return 'file';
      return null;
    }
    if (entry.isDirectory()) return 'dir';
    if (entry.isFile()) return 'file';
    return null;
  }

  async function walk(dir: string) {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      const kind = await classify(full, entry);
      if (kind === 'dir') {
        if (shouldSkipDir(entry.name)) {
          skippedDirs += 1;
          continue;
        }
        if (!(await shouldEnterDir(full))) continue;
        await walk(full);
      } else if (kind === 'file') {
        if (shouldSkipFile(full)) continue;
        const isSource =
          entry.name.endsWith('.swift') || entry.name.endsWith('.storyboard');
        if (!isSource) continue;
        if (!(await shouldEmitFile(full))) continue;
        if (entry.name.endsWith('.swift')) swift.push(full);
        else storyboard.push(full);
      }
    }
  }

  // Seed the visited set with the realpath of the root so a child symlink
  // pointing back at the root short-circuits.
  try {
    visitedRealPaths.add(await fs.realpath(rootDir));
  } catch {
    return { swift, storyboard, skippedDirs };
  }
  await walk(rootDir);
  return { swift, storyboard, skippedDirs };
}

export type ScanOpts = {
  rootDir: string;
  includeSummaries?: boolean;
};

// Validate that a `rootDir` override stays inside the active workspace —
// including when symlinks point out. The scanner walks the filesystem; an
// unconstrained override would let a misbehaving caller crawl `/`, `~`, or
// any sibling project on disk. Lexical containment (`path.relative`) is
// not enough: a `rootDir` inside the workspace could itself be a symlink
// pointing at `/etc`, and the walker happily follows symlinks.
//
// Returns null when `rootDir` is acceptable, or a string error message
// when it should be rejected. The caller (mcp.ts `scan_ios_app` handler)
// surfaces the message back to the model.
export type ScanScopeCheck =
  | { ok: true; absRoot: string }
  | { ok: false; reason: string };

export async function checkScanScope(
  rootDir: string | undefined,
  workspace: string | null,
): Promise<ScanScopeCheck> {
  if (!rootDir) {
    if (!workspace) {
      return {
        ok: false,
        reason: 'no workspace selected and no rootDir provided',
      };
    }
    return { ok: true, absRoot: path.resolve(workspace) };
  }
  // `rootDir` was explicitly supplied; validate even when no workspace is
  // set (a missing workspace is not a license to scan arbitrary paths).
  if (!path.isAbsolute(rootDir)) {
    return {
      ok: false,
      reason: `rootDir must be an absolute path; got ${rootDir}`,
    };
  }
  if (!workspace) {
    return {
      ok: false,
      reason: 'no workspace selected; rootDir overrides require a workspace',
    };
  }
  const absRoot = path.resolve(rootDir);
  const absWorkspace = path.resolve(workspace);
  // Lexical containment first.
  const rel = path.relative(absWorkspace, absRoot);
  if (rel.startsWith('..') || path.isAbsolute(rel)) {
    return {
      ok: false,
      reason: `rootDir must be inside the active workspace (${workspace}); got ${rootDir}`,
    };
  }
  // Symlink-safe containment: realpath both and re-check. A `rootDir` that
  // sits inside the workspace lexically but resolves to outside (e.g. a
  // symlink target in `/etc`) is rejected here.
  let realRoot: string;
  let realWorkspace: string;
  try {
    realRoot = await fs.realpath(absRoot);
    realWorkspace = await fs.realpath(absWorkspace);
  } catch (err) {
    return {
      ok: false,
      reason: `rootDir or workspace could not be resolved: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
  const realRel = path.relative(realWorkspace, realRoot);
  if (realRel.startsWith('..') || path.isAbsolute(realRel)) {
    return {
      ok: false,
      reason: `rootDir resolves outside the active workspace via a symlink; refusing to scan`,
    };
  }
  return { ok: true, absRoot: realRoot };
}

export async function scanIosScreens(opts: ScanOpts): Promise<ScanResult> {
  const includeSummaries = opts.includeSummaries ?? false;
  const cache = getCache().byPath;

  const { swift, storyboard, skippedDirs } = await walkSwiftSources(opts.rootDir);

  let scannedFiles = 0;
  let cachedFiles = 0;

  const allScreens: ScannedScreen[] = [];
  const allEdges: ScannedEdge[] = [];
  const entryIds = new Set<string>();
  // Track which cache keys we touched this scan so we can evict entries for
  // files that got deleted/renamed between calls. Without this, the cache
  // grows unboundedly across long-running dev sessions and stale files would
  // keep haunting the result. Only keys that share our `includeSummaries`
  // mode are tracked — the other mode's entries are out-of-band and stay
  // valid (they'll re-evict themselves on their own scan).
  const touchedKeys = new Set<string>();

  // Helper: read file with mtime check; honor cache when possible. The cache
  // key folds `includeSummaries` into the path — summary-on and summary-off
  // are disjoint cache namespaces. We deliberately do NOT alias the keyed
  // entry under the bare path: a follow-up scan in a different mode would
  // pick up the alias and silently return the wrong shape.
  async function processFile(
    abs: string,
    kind: 'swift' | 'storyboard',
  ): Promise<void> {
    let mtimeMs: number;
    try {
      const stat = await fs.stat(abs);
      mtimeMs = stat.mtimeMs;
    } catch {
      return;
    }
    const cacheKey = abs + (includeSummaries ? '|s' : '');
    touchedKeys.add(cacheKey);
    const cached = cache.get(cacheKey);
    if (cached && cached.mtimeMs === mtimeMs) {
      cachedFiles += 1;
      // Defensive copy: callers normalize `filePath` to be workspace-
      // relative, which used to mutate the cached array in place — a
      // subsequent scan from a different `rootDir` would then see the
      // previous root's paths. Copy so the cache stays canonical.
      for (const s of cached.screens) allScreens.push({ ...s });
      for (const e of cached.edges) allEdges.push({ ...e });
      for (const id of cached.entryIds) entryIds.add(id);
      return;
    }
    let content: string;
    try {
      content = await fs.readFile(abs, 'utf8');
    } catch {
      return;
    }
    scannedFiles += 1;

    let fileScreens: ScannedScreen[];
    let fileEdges: ScannedEdge[];
    let fileEntries: string[];
    if (kind === 'swift') {
      const swiftui = parseSwiftUIScreens(content, abs, includeSummaries);
      const uikit = parseUIKitScreens(content, abs);
      fileScreens = [...swiftui, ...uikit];
      // Edges originate from each screen declared in this file. Without a
      // proper AST we can't always tell which screen a navigation belongs to;
      // attribute every edge to every screen in the file is too noisy, so we
      // attribute to the first screen in declaration order — matches the
      // common case of one screen per file.
      const primary = fileScreens[0]?.id;
      fileEdges = primary ? parseSwiftEdges(content, primary) : [];
      fileEntries = detectEntryIds(content, 'swift');
    } else {
      fileScreens = parseStoryboardScreens(content, abs);
      const primary = fileScreens[0]?.id;
      fileEdges = primary ? parseStoryboardEdges(content, primary) : [];
      fileEntries = detectEntryIds(content, 'storyboard');
    }

    cache.set(cacheKey, {
      mtimeMs,
      screens: fileScreens,
      edges: fileEdges,
      entryIds: fileEntries,
    });

    // Push *copies* into the per-call result so downstream `filePath`
    // normalization can't mutate the cached array.
    for (const s of fileScreens) allScreens.push({ ...s });
    for (const e of fileEdges) allEdges.push({ ...e });
    for (const id of fileEntries) entryIds.add(id);
  }

  for (const abs of swift) await processFile(abs, 'swift');
  for (const abs of storyboard) await processFile(abs, 'storyboard');

  // Evict stale entries for files that no longer exist on disk in our mode.
  // This keeps the cache bounded across delete/rename cycles in long-lived
  // dev sessions; entries for the *other* `includeSummaries` mode are left
  // alone (they'll evict themselves on their own next scan).
  for (const key of [...cache.keys()]) {
    const isOurMode = includeSummaries ? key.endsWith('|s') : !key.endsWith('|s');
    if (!isOurMode) continue;
    if (!touchedKeys.has(key)) cache.delete(key);
  }

  // Normalize file paths to workspace-relative for the consumer. Operates on
  // the per-call copies built above, so the cache's canonical absolute paths
  // stay intact.
  const rel = (abs: string | undefined) =>
    abs ? path.relative(opts.rootDir, abs) : undefined;
  for (const s of allScreens) s.filePath = rel(s.filePath);

  // Mark entry screens. Only flag ids that exist in the screen set — the
  // raw `entryIds` may include type names that aren't themselves screens
  // (e.g. SwiftUI app structs, helper hosts).
  const screenIds = new Set(allScreens.map((s) => s.id));
  for (const s of allScreens) {
    if (entryIds.has(s.id) && screenIds.has(s.id)) {
      s.isEntry = true;
    }
  }

  // De-dupe edges: prefer the first occurrence of each (from, to, kind).
  const seenEdge = new Set<string>();
  const dedupedEdges: ScannedEdge[] = [];
  for (const e of allEdges) {
    const k = `${e.from}|${e.to}|${e.kind}`;
    if (seenEdge.has(k)) continue;
    seenEdge.add(k);
    dedupedEdges.push(e);
  }

  return {
    screens: allScreens,
    edges: dedupedEdges,
    scannedFiles,
    cachedFiles,
    skippedDirs,
  };
}
