import { describe, expect, it } from 'vitest';
import {
  bodyHasMarker,
  bodyMarkerLine,
  codeMask,
  declaredTypeNames,
  findViewStructBody,
  replaceStructBody,
} from './swiftScan';

// A realistic user file: two screen Views + a leaf component + an enum, with
// every lexing trap the scanner must survive sprinkled through it.
const SAMPLE = `import SwiftUI

// struct CommentedOut: View { var body: some View { Text("no") } }

struct TodoListView: View {
  @State private var newTask = ""
  /* block comment { with a brace
     /* and a NESTED block comment } */
     still inside */
  let title = "To-Do { not a brace }"
  let interp = "count: \\(items.map { $0.done }.count) ok"
  let multi = """
    quotes " and braces { } and \\(interp { x in x })
    """
  let raw = #"raw "quoted" \\(not-interp) {brace}"#

  var body: some View {
    VStack {
      Text(title)
      Button("Add") { add() }
    }
  }

  func add() { items.append(newTask) }
}

struct AuthView: View {
  struct Row: View {
    var body: some View { Text("nested row") }
  }
  public var body: some View {
    Row()
  }
}

enum Tab { case tasks, account }
`;

describe('codeMask', () => {
  const maskedSlice = (src: string, needle: string): boolean => {
    const i = src.indexOf(needle);
    if (i === -1) throw new Error(`needle not found: ${needle}`);
    return codeMask(src)[i] === 1;
  };

  it('marks plain code and keywords as code', () => {
    expect(maskedSlice(SAMPLE, 'struct TodoListView')).toBe(true);
    expect(maskedSlice(SAMPLE, 'func add')).toBe(true);
  });

  it('masks line comments out', () => {
    expect(maskedSlice(SAMPLE, 'CommentedOut')).toBe(false);
  });

  it('masks nested block comments out, including the inner close', () => {
    expect(maskedSlice(SAMPLE, 'NESTED block comment')).toBe(false);
    expect(maskedSlice(SAMPLE, 'still inside')).toBe(false);
    // Code right after the comment is code again.
    expect(maskedSlice(SAMPLE, 'let title')).toBe(true);
  });

  it('masks string contents (braces in strings are inert)', () => {
    expect(maskedSlice(SAMPLE, 'not a brace')).toBe(false);
  });

  it('masks interpolation interiors, then resumes the string correctly', () => {
    expect(maskedSlice(SAMPLE, '$0.done')).toBe(false);
    // The string keeps going after the interpolation: 'ok' is still content,
    // and the line's end quote terminates it (next let is code).
    expect(maskedSlice(SAMPLE, 'ok"')).toBe(false);
    expect(maskedSlice(SAMPLE, 'let multi')).toBe(true);
  });

  it('handles multiline strings with quotes, braces, and interpolation', () => {
    expect(maskedSlice(SAMPLE, 'quotes "')).toBe(false);
    expect(maskedSlice(SAMPLE, 'let raw')).toBe(true);
  });

  it('treats raw strings literally: \\( is not interpolation, " does not close', () => {
    expect(maskedSlice(SAMPLE, 'not-interp')).toBe(false);
    expect(maskedSlice(SAMPLE, '{brace}')).toBe(false);
    expect(maskedSlice(SAMPLE, 'var body: some View {\n    VStack')).toBe(true);
  });

  it('escaped quotes do not terminate strings', () => {
    const src = 'let s = "a \\" b"\nstruct X {}';
    expect(maskedSlice(src, 'struct X')).toBe(true);
    expect(maskedSlice(src, ' b"')).toBe(false);
  });

  it('recovers from an unterminated single-line string at newline', () => {
    const src = 'let s = "oops\nstruct X {}';
    expect(maskedSlice(src, 'struct X')).toBe(true);
  });
});

describe('findViewStructBody', () => {
  it('locates the body through comments, strings, and interpolation traps', () => {
    const found = findViewStructBody(SAMPLE, 'TodoListView');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    const inner = SAMPLE.slice(found.loc.bodyOpen + 1, found.loc.bodyClose);
    expect(inner).toContain('VStack');
    expect(inner).toContain('Button("Add") { add() }');
    expect(inner).not.toContain('func add');
    expect(found.loc.bodyIndent).toBe('  ');
    expect(found.loc.structIndent).toBe('');
  });

  it('never matches the commented-out struct', () => {
    const found = findViewStructBody(SAMPLE, 'CommentedOut');
    expect(found).toEqual({ ok: false, reason: 'struct-not-found' });
  });

  it('skips nested types and finds the OUTER body (modifier-prefixed)', () => {
    const found = findViewStructBody(SAMPLE, 'AuthView');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    const inner = SAMPLE.slice(found.loc.bodyOpen + 1, found.loc.bodyClose);
    expect(inner).toContain('Row()');
    expect(inner).not.toContain('nested row');
  });

  it('finds the nested type by its own name', () => {
    const found = findViewStructBody(SAMPLE, 'Row');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    const inner = SAMPLE.slice(found.loc.bodyOpen + 1, found.loc.bodyClose);
    expect(inner).toContain('nested row');
  });

  it('reports body-not-found for a struct without var body', () => {
    const src = 'struct Plain { let x = 1 }';
    expect(findViewStructBody(src, 'Plain')).toEqual({
      ok: false,
      reason: 'body-not-found',
    });
  });

  it('reports struct-unbalanced when the file is truncated mid-struct', () => {
    const src = 'struct Cut: View {\n  var body: some View {\n    Text("x")';
    expect(findViewStructBody(src, 'Cut')).toEqual({
      ok: false,
      reason: 'struct-unbalanced',
    });
  });

  it('handles generic and where-clause struct declarations', () => {
    const src = `struct Wrap<T: View>: View where T: Equatable {
  var body: some View { Text("g") }
}`;
    const found = findViewStructBody(src, 'Wrap');
    expect(found.ok).toBe(true);
  });

  it('does not confuse a same-prefix struct name', () => {
    const src = `struct HomeViewModel { }
struct HomeView: View { var body: some View { Text("h") } }`;
    const found = findViewStructBody(src, 'HomeView');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    const inner = src.slice(found.loc.bodyOpen + 1, found.loc.bodyClose);
    expect(inner).toContain('Text("h")');
  });
});

describe('replaceStructBody', () => {
  it('replaces only the body interior, byte-identical outside the braces', () => {
    const res = replaceStructBody(SAMPLE, 'TodoListView', 'Text("new")');
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.changed).toBe(true);
    expect(res.source).toContain('Text("new")');
    expect(res.source).not.toContain('VStack');
    // Everything outside the body survives untouched.
    expect(res.source).toContain('func add() { items.append(newTask) }');
    expect(res.source).toContain('let raw = #"raw "quoted"');
    expect(res.source).toContain('struct AuthView: View');
    expect(res.source).toContain('nested row');
    // Outside-of-body bytes are identical: prefix up to the body open brace.
    const before = findViewStructBody(SAMPLE, 'TodoListView');
    if (!before.ok) throw new Error('unreachable');
    expect(res.source.slice(0, before.loc.bodyOpen)).toBe(
      SAMPLE.slice(0, before.loc.bodyOpen),
    );
  });

  it('re-indents to the file style (body indent + inferred step)', () => {
    const res = replaceStructBody(SAMPLE, 'TodoListView', 'A()\n  .b()');
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.source).toContain('\n    A()\n      .b()\n  }');
  });

  it('falls back to 4-space step for flush-left declarations', () => {
    const src = `struct X: View {\nvar body: some View { Text("a") }\n}`;
    const res = replaceStructBody(src, 'X', 'Text("b")');
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.source).toContain('{\n    Text("b")\n}');
  });

  it('uses tab indentation when the file does', () => {
    const src = `struct X: View {\n\tvar body: some View {\n\t\tText("a")\n\t}\n}`;
    const res = replaceStructBody(src, 'X', 'Text("b")');
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.source).toContain('{\n\t\tText("b")\n\t}');
  });

  it('is idempotent: splicing the same content twice changes nothing', () => {
    const once = replaceStructBody(SAMPLE, 'TodoListView', 'Text("same")');
    if (!once.ok) throw new Error('splice failed');
    const twice = replaceStructBody(once.source, 'TodoListView', 'Text("same")');
    expect(twice.ok).toBe(true);
    if (!twice.ok) return;
    expect(twice.changed).toBe(false);
    expect(twice.source).toBe(once.source);
  });

  it('round-trips: the spliced body is findable and replaceable again', () => {
    const marker = bodyMarkerLine('todo-list');
    const once = replaceStructBody(
      SAMPLE,
      'TodoListView',
      `${marker}\nZStack(alignment: .topLeading) {\n  Text("v1 \\" tricky { }")\n}`,
    );
    if (!once.ok) throw new Error('splice failed');
    const found = findViewStructBody(once.source, 'TodoListView');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    expect(bodyHasMarker(once.source, found.loc)).toBe(true);
    const again = replaceStructBody(once.source, 'TodoListView', 'Text("v2")');
    expect(again.ok).toBe(true);
    if (!again.ok) return;
    expect(again.source).toContain('Text("v2")');
    expect(again.source).not.toContain('tricky');
    expect(again.source).toContain('func add()');
  });

  it('propagates locate failures', () => {
    expect(replaceStructBody(SAMPLE, 'Nope', 'Text("x")')).toEqual({
      ok: false,
      reason: 'struct-not-found',
    });
  });
});

describe('bodyHasMarker', () => {
  it('is false for hand-written bodies', () => {
    const found = findViewStructBody(SAMPLE, 'TodoListView');
    if (!found.ok) throw new Error('unreachable');
    expect(bodyHasMarker(SAMPLE, found.loc)).toBe(false);
  });
});

describe('declaredTypeNames', () => {
  it('collects real declarations and skips commented ones', () => {
    const names = declaredTypeNames(SAMPLE);
    expect(names.has('TodoListView')).toBe(true);
    expect(names.has('AuthView')).toBe(true);
    expect(names.has('Row')).toBe(true);
    expect(names.has('Tab')).toBe(true);
    expect(names.has('CommentedOut')).toBe(false);
  });
});
