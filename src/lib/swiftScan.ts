// Swift-aware source scanning for in-place export: locate a View struct's
// `var body` block in a user's .swift file and splice regenerated content
// into it, touching NOTHING outside the two body braces. No AST, no SwiftPM —
// a character-level scanner that knows exactly enough Swift lexing to make
// brace-matching safe: line comments, NESTED block comments, string literals
// (single-line, multiline """, raw #"…"#) and string interpolation \(…),
// which can carry arbitrarily nested braces/strings inside.
//
// Known, accepted lexing gap: Swift 5.7 BARE regex literals (`/[a-z]"/`) —
// indistinguishable from division without full parsing. Extended-delimiter
// regexes (`#/…/#`) ARE lexed. As a backstop for any residual desync,
// replaceStructBody re-locates the body in its own output and refuses to
// return a splice whose interior isn't exactly what it inserted — a desync
// surfaces as a loud failure, never a silently corrupted file.

// ── code mask ───────────────────────────────────────────────────────────────

type Ctx =
  // Base source code, or the inside of a \(…) interpolation (which is real
  // code but nothing we search for lives there — masked non-code; its braces
  // and parens are balanced, so skipping it never desyncs the outer match).
  | { kind: 'code'; interp: boolean; parens: number }
  | { kind: 'line' }
  | { kind: 'block'; depth: number }
  | { kind: 'string'; multi: boolean; hashes: number }
  // Extended-delimiter regex literal: #/…/# (flag-free Swift 5.7+). Interior
  // is masked so a `}` in a character class can't desync brace matching.
  | { kind: 'regex'; hashes: number };

// mask[i] === 1 ⇔ src[i] is plain top-level code: not comment, not string
// content/delimiter, not interpolation interior.
export function codeMask(src: string): Uint8Array {
  const mask = new Uint8Array(src.length);
  const stack: Ctx[] = [{ kind: 'code', interp: false, parens: 0 }];
  let i = 0;

  // How many '#'s sit at i (for raw-string delimiters / escapes).
  const hashRun = (at: number): number => {
    let n = 0;
    while (src[at + n] === '#') n += 1;
    return n;
  };

  while (i < src.length) {
    const ctx = stack[stack.length - 1];
    const ch = src[i];

    if (ctx.kind === 'line') {
      if (ch === '\n') stack.pop();
      i += 1;
      continue;
    }

    if (ctx.kind === 'block') {
      if (ch === '/' && src[i + 1] === '*') {
        ctx.depth += 1;
        i += 2;
        continue;
      }
      if (ch === '*' && src[i + 1] === '/') {
        ctx.depth -= 1;
        if (ctx.depth === 0) stack.pop();
        i += 2;
        continue;
      }
      i += 1;
      continue;
    }

    if (ctx.kind === 'regex') {
      if (ch === '\\') {
        i += 2; // escaped char inside the regex (\/ \# …)
        continue;
      }
      if (ch === '/' && hashRun(i + 1) === ctx.hashes) {
        stack.pop();
        i += 1 + ctx.hashes;
        continue;
      }
      i += 1;
      continue;
    }

    if (ctx.kind === 'string') {
      // Escape intro: '\' + exactly `hashes` '#'s. In raw strings a bare
      // backslash is literal content.
      if (ch === '\\' && hashRun(i + 1) === ctx.hashes) {
        const after = i + 1 + ctx.hashes;
        if (src[after] === '(') {
          stack.push({ kind: 'code', interp: true, parens: 1 });
          i = after + 1;
          continue;
        }
        i = after + 1; // consume the escaped char (\" \n \t \u…)
        continue;
      }
      if (ch === '"') {
        const close = ctx.multi ? 3 : 1;
        if (!ctx.multi || (src[i + 1] === '"' && src[i + 2] === '"')) {
          if (hashRun(i + close) === ctx.hashes) {
            stack.pop();
            i += close + ctx.hashes;
            continue;
          }
        }
      }
      if (!ctx.multi && ch === '\n') {
        // Unterminated single-line string — recover rather than swallow the
        // rest of the file.
        stack.pop();
      }
      i += 1;
      continue;
    }

    // code (base or interpolation)
    if (ch === '/' && src[i + 1] === '/') {
      stack.push({ kind: 'line' });
      i += 2;
      continue;
    }
    if (ch === '/' && src[i + 1] === '*') {
      stack.push({ kind: 'block', depth: 1 });
      i += 2;
      continue;
    }
    const hashes = ch === '#' ? hashRun(i) : 0;
    if (src[i + hashes] === '"') {
      const multi = src[i + hashes + 1] === '"' && src[i + hashes + 2] === '"';
      stack.push({ kind: 'string', multi, hashes });
      i += hashes + (multi ? 3 : 1);
      continue;
    }
    if (hashes > 0 && src[i + hashes] === '/') {
      stack.push({ kind: 'regex', hashes });
      i += hashes + 1;
      continue;
    }
    if (ctx.interp) {
      if (ch === '(') ctx.parens += 1;
      else if (ch === ')') {
        ctx.parens -= 1;
        if (ctx.parens === 0) {
          stack.pop(); // back to the enclosing string
          i += 1;
          continue;
        }
      }
      i += 1; // interpolation interior stays non-code
      continue;
    }
    mask[i] = 1;
    i += 1;
  }
  return mask;
}

// ── struct / body location ──────────────────────────────────────────────────

export type StructBodyLoc = {
  /** Index of the `struct` keyword. */
  structStart: number;
  /** Index of the struct's opening `{`. */
  structOpen: number;
  /** Index of the struct's matching `}`. */
  structClose: number;
  /** Index of the body block's opening `{`. */
  bodyOpen: number;
  /** Index of the body block's matching `}`. */
  bodyClose: number;
  /** Leading whitespace of the line containing `var body`. */
  bodyIndent: string;
  /** Leading whitespace of the line containing `struct`. */
  structIndent: string;
};

export type FindBodyFailure =
  | 'struct-not-found'
  | 'struct-ambiguous'
  | 'struct-unbalanced'
  | 'body-not-found'
  | 'body-unbalanced'
  | 'splice-verify-failed';

export type FindBodyResult =
  | { ok: true; loc: StructBodyLoc }
  | { ok: false; reason: FindBodyFailure };

function lineIndentAt(src: string, index: number): string {
  const start = src.lastIndexOf('\n', index - 1) + 1;
  let end = start;
  while (end < index && (src[end] === ' ' || src[end] === '\t')) end += 1;
  return src.slice(start, end);
}

// Matching close brace for the code-position `{` at `open` (-1 if the file
// ends first). Only mask-true braces count — string/comment braces are inert.
function matchBrace(src: string, mask: Uint8Array, open: number): number {
  let depth = 1;
  for (let i = open + 1; i < src.length; i++) {
    if (!mask[i]) continue;
    if (src[i] === '{') depth += 1;
    else if (src[i] === '}') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * Locate `struct <name>`'s `var body` block. The body must sit at the
 * struct's own nesting depth (a nested helper type's `var body` is never
 * matched). Replacing the outer brace block of an explicit-getter body
 * (`var body: some View { get { … } }`) collapses the getter — acceptable;
 * SwiftUI bodies in practice are plain implicit-getter computed properties.
 */
export function findViewStructBody(
  src: string,
  structName: string,
): FindBodyResult {
  const mask = codeMask(src);

  // Unicode identifier capture: ASCII-only classes would truncate `Café` to
  // `Caf` and silently splice the wrong struct on an exact-name search.
  const structRe = /\bstruct\s+([\p{ID_Start}_][\p{ID_Continue}_]*)/gu;
  const matches: Array<{ start: number; nameEnd: number }> = [];
  for (const m of src.matchAll(structRe)) {
    if (!mask[m.index]) continue;
    if (m[1] !== structName) continue;
    matches.push({ start: m.index, nameEnd: m.index + m[0].length });
  }
  if (matches.length === 0) return { ok: false, reason: 'struct-not-found' };

  // Several same-named structs can coexist (a top-level View plus a
  // namespaced `extension Screens { struct Detail … }`). Prefer the
  // top-level (brace-depth-0) declaration; if that doesn't single one out,
  // fail loudly rather than splice the first textual occurrence.
  let chosen = matches[0];
  if (matches.length > 1) {
    let depth = 0;
    let at = 0;
    const depthAt = (index: number): number => {
      for (; at < index; at++) {
        if (!mask[at]) continue;
        if (src[at] === '{') depth += 1;
        else if (src[at] === '}') depth -= 1;
      }
      return depth;
    };
    const topLevel = matches.filter((m) => depthAt(m.start) === 0);
    if (topLevel.length !== 1) return { ok: false, reason: 'struct-ambiguous' };
    chosen = topLevel[0];
  }
  const { start: structStart, nameEnd } = chosen;

  // First code-position '{' after the name is the struct body — generic
  // params, inheritance clauses, and where-clauses carry no braces.
  let structOpen = -1;
  for (let i = nameEnd; i < src.length; i++) {
    if (mask[i] && src[i] === '{') {
      structOpen = i;
      break;
    }
  }
  if (structOpen === -1) return { ok: false, reason: 'struct-unbalanced' };
  const structClose = matchBrace(src, mask, structOpen);
  if (structClose === -1) return { ok: false, reason: 'struct-unbalanced' };

  // `var body` at depth 1 of the struct (a nested type's body never matches).
  const bodyRe = /\bvar\s+body\b/g;
  let candidate = -1;
  let candidateEnd = -1;
  for (const m of src.slice(structOpen + 1, structClose).matchAll(bodyRe)) {
    const at = structOpen + 1 + m.index;
    if (!mask[at]) continue;
    let depth = 1;
    for (let i = structOpen + 1; i < at; i++) {
      if (!mask[i]) continue;
      if (src[i] === '{') depth += 1;
      else if (src[i] === '}') depth -= 1;
    }
    if (depth === 1) {
      candidate = at;
      candidateEnd = at + m[0].length;
      break;
    }
  }
  if (candidate === -1) return { ok: false, reason: 'body-not-found' };

  let bodyOpen = -1;
  for (let i = candidateEnd; i < structClose; i++) {
    if (mask[i] && src[i] === '{') {
      bodyOpen = i;
      break;
    }
  }
  if (bodyOpen === -1) return { ok: false, reason: 'body-not-found' };

  // The `{` must belong to THIS declaration. A computed body only ever has a
  // type annotation between `var body` and its block (`: some View`, generic
  // brackets, optionals). A STORED `var body = …` (legal — it satisfies View)
  // followed by another member would otherwise bind bodyOpen to that NEXT
  // member's brace and splice generated code into it. Reject any span
  // carrying an initializer, statement separator, attribute, or a fresh
  // declaration keyword — better a loud body-not-found than a wrong-target
  // splice.
  let span = '';
  for (let i = candidateEnd; i < bodyOpen; i++) {
    if (mask[i]) span += src[i];
  }
  if (
    /[=;@]/.test(span) ||
    /\b(func|var|let|init|deinit|subscript|struct|class|enum|protocol|extension|typealias|case|import)\b/.test(
      span,
    )
  ) {
    return { ok: false, reason: 'body-not-found' };
  }
  const bodyClose = matchBrace(src, mask, bodyOpen);
  if (bodyClose === -1 || bodyClose > structClose) {
    return { ok: false, reason: 'body-unbalanced' };
  }

  return {
    ok: true,
    loc: {
      structStart,
      structOpen,
      structClose,
      bodyOpen,
      bodyClose,
      bodyIndent: lineIndentAt(src, candidate),
      structIndent: lineIndentAt(src, structStart),
    },
  };
}

// ── body replacement ────────────────────────────────────────────────────────

export type ReplaceBodyResult =
  | { ok: true; source: string; changed: boolean }
  | { ok: false; reason: FindBodyFailure };

/**
 * Replace the interior of `struct <name>`'s body block with `newInner`
 * (unindented multi-line content; relative indentation preserved). The
 * spliced block re-indents to the file's own style: body-line indent + one
 * step (inferred from the struct→body delta, falling back to 4 spaces).
 * Everything outside the two body braces is byte-identical.
 */
export function replaceStructBody(
  src: string,
  structName: string,
  newInner: string,
): ReplaceBodyResult {
  const found = findViewStructBody(src, structName);
  if (!found.ok) return found;
  const { bodyOpen, bodyClose, bodyIndent, structIndent } = found.loc;

  const step =
    bodyIndent.startsWith(structIndent) && bodyIndent.length > structIndent.length
      ? bodyIndent.slice(structIndent.length)
      : '    ';
  const inner = newInner
    .split('\n')
    .map((l) => (l.length > 0 ? bodyIndent + step + l : l))
    .join('\n');
  const next =
    src.slice(0, bodyOpen) +
    '{\n' +
    inner +
    '\n' +
    bodyIndent +
    '}' +
    src.slice(bodyClose + 1);

  // Verify the splice against any residual lexer desync (the bare-regex gap,
  // future Swift syntax): re-locate the body in OUR OWN OUTPUT and require
  // its interior to be exactly what we inserted. A mismatch means the
  // original location was wrong — refuse loudly, never hand back a
  // corrupted file.
  const check = findViewStructBody(next, structName);
  if (
    !check.ok ||
    next.slice(check.loc.bodyOpen + 1, check.loc.bodyClose) !==
      `\n${inner}\n${bodyIndent}`
  ) {
    return { ok: false, reason: 'splice-verify-failed' };
  }
  return { ok: true, source: next, changed: next !== src };
}

/**
 * Blank out the interior of every tango-marked body block — used by the
 * design-system scanner so tango's own generated output (theme background
 * colors, spacing) can't feed back into the next import's token extraction.
 * Conservative: a marker whose enclosing block can't be resolved is left
 * in place (over-counting beats mangling the scan input).
 */
export function stripTangoBodyBlocks(src: string): string {
  let out = src;
  for (let guard = 0; guard < 64; guard++) {
    const idx = out.indexOf(BODY_MARKER);
    if (idx === -1) break;
    const mask = codeMask(out);
    let open = -1;
    for (let i = idx; i >= 0; i--) {
      if (mask[i] && out[i] === '{') {
        open = i;
        break;
      }
    }
    if (open === -1) break;
    const close = matchBrace(out, mask, open);
    if (close === -1 || close < idx) break;
    out = out.slice(0, open + 1) + out.slice(close);
  }
  return out;
}

// ── tango body marker ───────────────────────────────────────────────────────
// First line of every exported body. Load-bearing twice over: a marked body
// is provably tango-generated (safe to overwrite even when the file changed
// since import), and the screen id lets a later import round-trip the struct
// back onto the same canvas screen.

export const BODY_MARKER = 'tango:body';

export function bodyMarkerLine(screenId: string): string {
  return `// ${BODY_MARKER} v=1 screen=${screenId} — managed by tango; edit the design on the canvas (Export & Run regenerates this body)`;
}

/** Does the located body block already carry the tango:body marker? */
export function bodyHasMarker(src: string, loc: StructBodyLoc): boolean {
  return src.slice(loc.bodyOpen, loc.bodyClose + 1).includes(BODY_MARKER);
}

/**
 * First needle that appears as a whole word at a CODE position in a Swift
 * fragment (null when none do). A body interior is a valid standalone
 * fragment — it starts in code context right after the body's `{`. Word
 * boundaries keep `TabView` from matching `.tabViewStyle` or `TabViewState`;
 * the mask keeps it from matching inside strings and comments.
 */
export function codeContainsWord(
  fragment: string,
  needles: string[],
): string | null {
  if (needles.length === 0) return null;
  const mask = codeMask(fragment);
  const re = new RegExp(
    `\\b(?:${needles.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})\\b`,
    'g',
  );
  for (const m of fragment.matchAll(re)) {
    if (mask[m.index]) return m[0];
  }
  return null;
}

// ── declared type names ─────────────────────────────────────────────────────

/**
 * Every type name declared in this source (mask-aware, so a commented-out
 * `// struct Foo` doesn't count). Used to pick collision-free names for new
 * screen files.
 */
export function declaredTypeNames(src: string): Set<string> {
  const mask = codeMask(src);
  const out = new Set<string>();
  const re =
    /\b(?:struct|class|enum|actor|protocol|typealias)\s+([\p{ID_Start}_][\p{ID_Continue}_]*)/gu;
  for (const m of src.matchAll(re)) {
    if (mask[m.index]) out.add(m[1]);
  }
  return out;
}
