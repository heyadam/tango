import { describe, expect, it } from 'vitest';
import {
  bodyHasMarker,
  bodyMarkerLine,
  codeContainsWord,
  codeMask,
  declaredTypeNames,
  findViewStructBody,
  replaceStructBody,
  stripTangoBodyBlocks,
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

// Attacks confirmed by the adversarial review — every case here previously
// produced a SILENT wrong-target or corrupting splice.
describe('findViewStructBody — wrong-target hardening', () => {
  it('refuses a STORED `var body` property instead of splicing the next member', () => {
    const src = `struct StoredBodyView: View {
  var body = AnyView(Text("stored"))

  func helper() {
    print("user logic")
  }
}`;
    expect(findViewStructBody(src, 'StoredBodyView')).toEqual({
      ok: false,
      reason: 'body-not-found',
    });
    const rep = replaceStructBody(src, 'StoredBodyView', 'Text("NEW")');
    expect(rep.ok).toBe(false);
  });

  it('refuses a stored body with a didSet observer block', () => {
    const src = `struct ObservedView: View {
  var body = Text("stored") {
    didSet { print("changed") }
  }
}`;
    expect(findViewStructBody(src, 'ObservedView')).toEqual({
      ok: false,
      reason: 'body-not-found',
    });
  });

  it('refuses an annotation-only stored body followed by a function', () => {
    const src = `struct Request {
  var body: Data

  func validate() -> Bool {
    true
  }
}`;
    expect(findViewStructBody(src, 'Request')).toEqual({
      ok: false,
      reason: 'body-not-found',
    });
  });

  it('still accepts computed bodies with comments inside the annotation', () => {
    const src = `struct Ok: View {
  var body: /* the view */ some View {
    Text("fine")
  }
}`;
    const found = findViewStructBody(src, 'Ok');
    expect(found.ok).toBe(true);
  });

  it('masks extended regex literals: a } inside #/…/# cannot desync the body braces', () => {
    const src = `struct RegexView: View {
  var body: some View {
    let bad = text.firstMatch(of: #/[}]/#)
    return Text("old")
  }

  func keepMe() {}
}`;
    const found = findViewStructBody(src, 'RegexView');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    const inner = src.slice(found.loc.bodyOpen + 1, found.loc.bodyClose);
    expect(inner).toContain('return Text("old")');
    const rep = replaceStructBody(src, 'RegexView', 'Text("NEW")');
    expect(rep.ok).toBe(true);
    if (!rep.ok) return;
    expect(rep.source).toContain('func keepMe() {}');
    expect(rep.source).not.toContain(']/#)');
  });

  it('captures full Unicode identifiers — Café never matches a search for Caf', () => {
    const src = `struct Café: View { var body: some View { Text("café") } }
struct Caf: View { var body: some View { Text("caf") } }`;
    const found = findViewStructBody(src, 'Caf');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    expect(src.slice(found.loc.bodyOpen, found.loc.bodyClose)).toContain('caf');
    expect(src.slice(found.loc.bodyOpen, found.loc.bodyClose)).not.toContain('café');
    expect(declaredTypeNames(src).has('Café')).toBe(true);
  });

  it('prefers the top-level struct over a same-named nested one', () => {
    const src = `extension Screens {
  struct Detail: View {
    var body: some View { Text("nested") }
  }
}

struct Detail: View {
  var body: some View { Text("top-level") }
}`;
    const found = findViewStructBody(src, 'Detail');
    expect(found.ok).toBe(true);
    if (!found.ok) return;
    expect(src.slice(found.loc.bodyOpen, found.loc.bodyClose)).toContain('top-level');
  });

  it('fails loudly on truly ambiguous same-named structs', () => {
    const src = `extension A { struct Detail: View { var body: some View { Text("a") } } }
extension B { struct Detail: View { var body: some View { Text("b") } } }`;
    expect(findViewStructBody(src, 'Detail')).toEqual({
      ok: false,
      reason: 'struct-ambiguous',
    });
  });
});

describe('stripTangoBodyBlocks', () => {
  it('blanks marked body interiors and leaves the rest of the file intact', () => {
    const src = `struct A: View {
  var body: some View {
    ${bodyMarkerLine('a')}
    ZStack { Text("x").background(Color(red: 0.9, green: 0.9, blue: 0.8, opacity: 1)) }
  }
  func keep() -> Int { 7 }
}
struct B: View {
  var body: some View {
    Text("hand written").foregroundColor(Color(red: 0.1, green: 0.2, blue: 0.3, opacity: 1))
  }
}`;
    const out = stripTangoBodyBlocks(src);
    expect(out).not.toContain('0.9');
    expect(out).not.toContain('tango:body');
    expect(out).toContain('func keep() -> Int { 7 }');
    expect(out).toContain('hand written');
    expect(out).toContain('0.3');
  });

  it('is a no-op without markers', () => {
    const src = 'struct X: View { var body: some View { Text("a") } }';
    expect(stripTangoBodyBlocks(src)).toBe(src);
  });
});

describe('codeContainsWord', () => {
  it('matches whole words at code positions only', () => {
    const frag = `// TabView in a comment
let s = "TabView in a string"
Text("x").tabViewStyle(.page)
TabViewStateThing()
`;
    expect(codeContainsWord(frag, ['TabView'])).toBeNull();
    expect(codeContainsWord(`${frag}TabView { Text("t") }`, ['TabView'])).toBe('TabView');
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
