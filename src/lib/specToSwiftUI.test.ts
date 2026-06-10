import { describe, expect, it } from 'vitest';
import {
  emitScreenBody,
  emitScreenFile,
  fmt,
  fmtChannel,
  screenFileNames,
  screenTypeName,
  structCandidates,
  swiftStringLiteral,
} from './specToSwiftUI';
import { resolveSpec } from './uiResolve';
import { BODY_MARKER } from './swiftScan';
import type { UINode, UISpec } from './uiMockProtocol';

function node(partial: Partial<UINode> & Pick<UINode, 'id' | 'type'>): UINode {
  return { x: 0, y: 0, width: 100, height: 40, ...partial };
}

// One screen exercising all 10 node types + off-theme styling.
const KITCHEN_SINK: UISpec = {
  screens: [
    {
      id: 'kitchen-sink',
      title: 'Kitchen Sink',
      frame: { w: 390, h: 844 },
      nodes: [
        node({ id: 'bg', type: 'div', x: 0, y: 0, width: 390, height: 200, style: { background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)' } }),
        node({ id: 'h1', type: 'heading', x: 24, y: 60, width: 342, height: 40, text: 'Welcome "back"', props: { level: 1 } }),
        node({ id: 'sub', type: 'text', x: 24, y: 104, width: 342, height: 20, text: 'Line one\nLine two', className: 'text-muted-foreground text-center' }),
        node({ id: 'email', type: 'Input', x: 24, y: 240, width: 342, height: 40, props: { placeholder: 'Email' } }),
        node({ id: 'bio', type: 'Textarea', x: 24, y: 296, width: 342, height: 96, props: { placeholder: 'Tell us about yourself' } }),
        node({ id: 'cta', type: 'Button', x: 24, y: 700, width: 342, height: 44, text: 'Sign in', style: { backgroundColor: '#0E7C66', color: '#ffffff' } }),
        node({ id: 'ghost', type: 'Button', x: 24, y: 752, width: 342, height: 36, text: 'Skip', props: { variant: 'ghost' } }),
        node({ id: 'new', type: 'Badge', x: 300, y: 16, width: 66, height: 22, text: 'New', props: { variant: 'secondary' } }),
        node({ id: 'rule', type: 'Separator', x: 24, y: 420, width: 342, height: 8 }),
        node({ id: 'avatar', type: 'Image', x: 24, y: 440, width: 64, height: 64, props: { src: 'https://example.test/a.png' } }),
        node({ id: 'photo', type: 'Image', x: 100, y: 440, width: 64, height: 64 }),
        node({ id: 'gear', type: 'Icon', x: 340, y: 60, width: 24, height: 24, props: { iconName: 'Settings' } }),
      ],
    },
  ],
};

// One screen exercising all 6 shape types + the fill/stroke channels.
const SHAPES: UISpec = {
  screens: [
    {
      id: 'shapes',
      title: 'Shapes',
      frame: { w: 390, h: 844 },
      nodes: [
        node({ id: 'r1', type: 'rect', x: 24, y: 24, width: 160, height: 120 }),
        node({ id: 'r2', type: 'rect', x: 200, y: 24, width: 160, height: 120, className: 'bg-primary rounded-xl border-2 border-foreground' }),
        node({ id: 'e1', type: 'ellipse', x: 24, y: 170, width: 120, height: 80, className: 'bg-secondary border border-dashed' }),
        node({ id: 'l1', type: 'line', x: 24, y: 280, width: 200, height: 8 }),
        node({ id: 'l2', type: 'line', x: 24, y: 300, width: 120, height: 90, className: 'border-4 border-destructive border-dashed', props: { end: 'ne' } }),
        node({ id: 'a1', type: 'arrow', x: 24, y: 420, width: 200, height: 60, className: 'border-2 border-primary', props: { end: 'se' } }),
        node({ id: 't1', type: 'triangle', x: 24, y: 520, width: 120, height: 104, className: 'bg-warning' }),
        node({ id: 's1', type: 'star', x: 180, y: 520, width: 120, height: 120, className: 'bg-primary/60 border border-primary', props: { points: 5 } }),
        node({ id: 's2', type: 'star', x: 24, y: 660, width: 100, height: 100, props: { points: 8 }, style: { background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)', opacity: 0.9 } }),
      ],
    },
  ],
};

const TWO_SCREEN_FLOW: UISpec = {
  screens: [
    {
      id: 'login',
      title: 'Login',
      frame: { w: 390, h: 844 },
      nodes: [node({ id: 'cta', type: 'Button', x: 24, y: 700, width: 342, height: 44, text: 'Sign in' })],
    },
    {
      id: 'dashboard',
      title: 'Dashboard',
      frame: { w: 390, h: 844 },
      nodes: [node({ id: 'title', type: 'heading', x: 24, y: 60, width: 342, height: 40, text: 'Dashboard' })],
    },
  ],
};

// id → {screen file content} the way the export pipeline assembles new files.
function emitFiles(spec: UISpec): Map<string, string> {
  const resolved = resolveSpec(spec);
  const names = screenFileNames(spec);
  const out = new Map<string, string>();
  for (const screen of resolved.screens) {
    const file = names.get(screen.id)!;
    out.set(file, emitScreenFile(screen, file.replace(/\.swift$/, '')));
  }
  return out;
}

describe('swiftStringLiteral', () => {
  it('escapes quotes, backslashes, and newlines', () => {
    expect(swiftStringLiteral('a "b" \\ c\nd')).toBe('"a \\"b\\" \\\\ c\\nd"');
  });

  it('passes emoji through and escapes control chars', () => {
    expect(swiftStringLiteral('hi 👋')).toBe('"hi 👋"');
    expect(swiftStringLiteral('ab')).toBe('"a\\u{7}b"');
  });
});

describe('fmt', () => {
  it('emits integers bare and trims decimals to ≤3 places', () => {
    expect(fmt(42)).toBe('42');
    expect(fmt(0.5)).toBe('0.5');
    expect(fmt(1 / 3)).toBe('0.333');
    expect(fmt(2.1000001)).toBe('2.1');
  });
});

describe('fmtChannel', () => {
  it('maps 8-bit channels onto exact-enough 0–1 literals', () => {
    expect(fmtChannel(0)).toBe('0');
    expect(fmtChannel(255)).toBe('1');
    expect(fmtChannel(34)).toBe('0.13333');
    expect(fmtChannel(128)).toBe('0.50196');
  });

  it('round-trips every 8-bit value distinctly', () => {
    const seen = new Set<string>();
    for (let i = 0; i <= 255; i += 1) seen.add(fmtChannel(i));
    expect(seen.size).toBe(256);
  });
});

describe('screenTypeName', () => {
  it('pascal-cases ids with a Screen suffix (no Tango prefix)', () => {
    expect(screenTypeName('login', new Set())).toBe('LoginScreen');
    expect(screenTypeName('user-profile', new Set())).toBe('UserProfileScreen');
  });

  it('keeps existing View/Screen suffixes', () => {
    expect(screenTypeName('OnboardingView', new Set())).toBe('OnboardingView');
  });

  it('dedupes deterministically against a caller-seeded taken set', () => {
    const taken = new Set<string>(['LoginScreen']);
    expect(screenTypeName('login', taken)).toBe('LoginScreen2');
    expect(screenTypeName('login', taken)).toBe('LoginScreen3');
  });

  it('survives ids with no usable characters', () => {
    expect(screenTypeName('---', new Set())).toBe('Screen');
  });
});

describe('screenFileNames', () => {
  it('derives the new-file target per screen', () => {
    const names = screenFileNames(TWO_SCREEN_FLOW);
    expect(names.get('login')).toBe('LoginScreen.swift');
    expect(names.get('dashboard')).toBe('DashboardScreen.swift');
  });

  it('seeds taken with identifier-shaped screen ids (linked struct names)', () => {
    const names = screenFileNames({
      screens: [
        { id: 'LoginScreen', title: 'Login', frame: { w: 390, h: 844 }, nodes: [], sourceFile: 'App/Login.swift' },
        { id: 'login-screen', title: 'Login 2', frame: { w: 390, h: 844 }, nodes: [] },
      ],
    });
    // The unlinked screen must not claim the linked screen's struct name.
    expect(names.get('login-screen')).toBe('LoginScreen2.swift');
  });

  it('dedupes collisions in spec order: reversing screen order swaps the suffix', () => {
    const a = { id: 'login-screen', title: 'Login', frame: { w: 390, h: 844 }, nodes: [] };
    const b = { id: 'login_screen', title: 'Login 2', frame: { w: 390, h: 844 }, nodes: [] };
    const forward = screenFileNames({ screens: [a, b] });
    expect(forward.get('login-screen')).toBe('LoginScreen.swift');
    expect(forward.get('login_screen')).toBe('LoginScreen2.swift');
    const reversed = screenFileNames({ screens: [b, a] });
    expect(reversed.get('login_screen')).toBe('LoginScreen.swift');
    expect(reversed.get('login-screen')).toBe('LoginScreen2.swift');
  });
});

describe('structCandidates', () => {
  it('tries the exact id first (import names screens after the View type)', () => {
    expect(
      structCandidates({ id: 'TodoListView', title: 'TodoListView' }),
    ).toEqual(['TodoListView']);
  });

  it('falls back to PascalCase(id) and the title for renamed screens', () => {
    expect(structCandidates({ id: 'todo-list', title: 'TodoListView' })).toEqual([
      'TodoList',
      'TodoListView',
    ]);
  });

  it('filters non-identifier titles', () => {
    expect(structCandidates({ id: 'todo-list', title: 'My Tasks!' })).toEqual([
      'TodoList',
    ]);
  });
});

describe('emitScreenBody', () => {
  const body = () => emitScreenBody(resolveSpec(KITCHEN_SINK).screens[0]);

  it('is deterministic', () => {
    expect(body()).toBe(body());
  });

  it('opens with the tango:body marker carrying the screen id', () => {
    const first = body().split('\n')[0];
    expect(first).toContain(BODY_MARKER);
    expect(first).toContain('screen=kitchen-sink');
    expect(first.startsWith('//')).toBe(true);
  });

  it('uses the shared layout convention: ZStack + frame().offset(), never .position()', () => {
    const b = body();
    expect(b).toContain('ZStack(alignment: .topLeading) {');
    expect(b).toContain('.frame(width: 390, height: 844, alignment: .topLeading)');
    expect(b).toContain('.offset(x: 24, y: 700)');
    expect(b).not.toContain('.position(');
    expect(b.endsWith('.clipped()')).toBe(true);
  });

  it('emits self-contained sRGB color literals (no support-file helper)', () => {
    const b = body();
    expect(b).toContain('Color(red: ');
    expect(b).not.toContain('tangoR');
  });

  it('renders an empty screen as EmptyView()', () => {
    const empty = resolveSpec({
      screens: [{ id: 'e', title: 'E', frame: { w: 100, h: 100 }, nodes: [] }],
    }).screens[0];
    expect(emitScreenBody(empty)).toContain('EmptyView()');
  });

  it('chunks >10 nodes into Groups so ViewBuilder compiles', () => {
    const many: UISpec = {
      screens: [
        {
          id: 'many',
          title: 'Many',
          frame: { w: 390, h: 844 },
          nodes: Array.from({ length: 23 }, (_, i) =>
            node({ id: `n${i}`, type: 'text', y: i * 30, text: `Row ${i}` }),
          ),
        },
      ],
    };
    const b = emitScreenBody(resolveSpec(many).screens[0]);
    // 23 nodes → 3 groups of ≤10 at the top level.
    expect(b.match(/Group \{/g)!.length).toBe(3);
  });

  it('emits shape geometry as literal points, never re-derived', () => {
    const b = emitScreenBody(resolveSpec(SHAPES).screens[0]);
    // The horizontal line's resolved midline points.
    expect(b).toContain('p.move(to: CGPoint(x: 0, y: 4))');
    expect(b).toContain('p.addLine(to: CGPoint(x: 200, y: 4))');
    // Triangle closes its ring.
    expect(b).toContain('p.closeSubpath()');
    // Ellipse is a true Ellipse, not a capsule.
    expect(b).toContain('Ellipse()');
    expect(b).not.toContain('.position(');
  });
});

describe('emitScreenFile', () => {
  it('wraps exactly emitScreenBody inside the struct (creation == later splice)', () => {
    const screen = resolveSpec(TWO_SCREEN_FLOW).screens[0];
    const file = emitScreenFile(screen, 'LoginScreen');
    const indented = emitScreenBody(screen)
      .split('\n')
      .map((l) => (l.length > 0 ? `    ${l}` : l))
      .join('\n');
    expect(file).toContain(`var body: some View {\n${indented}\n  }`);
  });

  it('declares the struct, a #Preview, and no DO-NOT-EDIT whole-file claim', () => {
    const screen = resolveSpec(TWO_SCREEN_FLOW).screens[1];
    const file = emitScreenFile(screen, 'DashboardScreen');
    expect(file).toContain('struct DashboardScreen: View {');
    expect(file).toContain('#Preview {\n  DashboardScreen()\n}');
    expect(file).not.toContain('tango:generated');
    expect(file).not.toContain('DO NOT EDIT');
  });

  it('is deterministic: two runs produce byte-identical files', () => {
    const a = emitFiles(KITCHEN_SINK);
    const b = emitFiles(KITCHEN_SINK);
    expect([...a.keys()]).toEqual([...b.keys()]);
    for (const [path, content] of a) expect(content).toBe(b.get(path));
  });

  it('matches the kitchen-sink golden files', async () => {
    for (const [path, content] of emitFiles(KITCHEN_SINK)) {
      await expect(content).toMatchFileSnapshot(
        `__snapshots__/specToSwiftUI/kitchen-sink/${path}`,
      );
    }
  });

  it('matches the two-screen-flow golden files', async () => {
    for (const [path, content] of emitFiles(TWO_SCREEN_FLOW)) {
      await expect(content).toMatchFileSnapshot(
        `__snapshots__/specToSwiftUI/two-screen-flow/${path}`,
      );
    }
  });

  it('matches the shapes golden files', async () => {
    for (const [path, content] of emitFiles(SHAPES)) {
      await expect(content).toMatchFileSnapshot(
        `__snapshots__/specToSwiftUI/shapes/${path}`,
      );
    }
  });
});
