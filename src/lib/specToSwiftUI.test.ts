import { describe, expect, it } from 'vitest';
import {
  fmt,
  screenFileNames,
  screenTypeName,
  specToSwiftUI,
  swiftStringLiteral,
} from './specToSwiftUI';
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

describe('screenTypeName', () => {
  it('pascal-cases ids with a Tango prefix and Screen suffix', () => {
    expect(screenTypeName('login', new Set())).toBe('TangoLoginScreen');
    expect(screenTypeName('user-profile', new Set())).toBe('TangoUserProfileScreen');
  });

  it('keeps existing View/Screen suffixes', () => {
    expect(screenTypeName('OnboardingView', new Set())).toBe('TangoOnboardingView');
  });

  it('dedupes deterministically', () => {
    const taken = new Set<string>();
    expect(screenTypeName('login', taken)).toBe('TangoLoginScreen');
    expect(screenTypeName('login', taken)).toBe('TangoLoginScreen2');
    expect(screenTypeName('login', taken)).toBe('TangoLoginScreen3');
  });

  it('survives ids with no usable characters', () => {
    expect(screenTypeName('---', new Set())).toBe('TangoScreen');
  });
});

describe('screenFileNames', () => {
  it('matches the screen .swift paths specToSwiftUI emits for the golden fixtures', () => {
    for (const spec of [KITCHEN_SINK, TWO_SCREEN_FLOW]) {
      const names = screenFileNames(spec);
      const emitted = specToSwiftUI(spec).files.map((f) => f.path);
      expect(emitted).toEqual([
        'TangoSupport.swift',
        ...spec.screens.map((s) => names.get(s.id)!),
        'TangoGeneratedIndex.swift',
      ]);
    }
  });

  it('dedupes collisions in spec order: reversing screen order swaps the suffix', () => {
    const a = { id: 'login-screen', title: 'Login', frame: { w: 390, h: 844 }, nodes: [] };
    const b = { id: 'login_screen', title: 'Login 2', frame: { w: 390, h: 844 }, nodes: [] };
    const forward = screenFileNames({ screens: [a, b] });
    expect(forward.get('login-screen')).toBe('TangoLoginScreen.swift');
    expect(forward.get('login_screen')).toBe('TangoLoginScreen2.swift');
    const reversed = screenFileNames({ screens: [b, a] });
    expect(reversed.get('login_screen')).toBe('TangoLoginScreen.swift');
    expect(reversed.get('login-screen')).toBe('TangoLoginScreen2.swift');
  });
});

describe('specToSwiftUI', () => {
  it('is deterministic: two runs produce byte-identical files', () => {
    const a = specToSwiftUI(KITCHEN_SINK);
    const b = specToSwiftUI(KITCHEN_SINK);
    expect(a.files.length).toBe(b.files.length);
    for (let i = 0; i < a.files.length; i += 1) {
      expect(a.files[i].path).toBe(b.files[i].path);
      expect(a.files[i].content).toBe(b.files[i].content);
    }
  });

  it('emits support + one file per screen + index, in order', () => {
    const { files } = specToSwiftUI(TWO_SCREEN_FLOW);
    expect(files.map((f) => f.path)).toEqual([
      'TangoSupport.swift',
      'TangoLoginScreen.swift',
      'TangoDashboardScreen.swift',
      'TangoGeneratedIndex.swift',
    ]);
  });

  it('marks every file with the tango:generated header', () => {
    const { files } = specToSwiftUI(TWO_SCREEN_FLOW);
    for (const f of files) {
      expect(f.content.split('\n')[1]).toContain('tango:generated v=1');
    }
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
    const { files } = specToSwiftUI(many);
    const screen = files[1].content;
    expect(screen).toContain('Group {');
    // 23 nodes → 3 groups of ≤10 at the top level.
    expect(screen.match(/Group \{/g)!.length).toBe(3);
  });

  it('matches the kitchen-sink golden files', async () => {
    const { files } = specToSwiftUI(KITCHEN_SINK);
    for (const f of files) {
      await expect(f.content).toMatchFileSnapshot(
        `__snapshots__/specToSwiftUI/kitchen-sink/${f.path}`,
      );
    }
  });

  it('matches the two-screen-flow golden files', async () => {
    const { files } = specToSwiftUI(TWO_SCREEN_FLOW);
    for (const f of files) {
      await expect(f.content).toMatchFileSnapshot(
        `__snapshots__/specToSwiftUI/two-screen-flow/${f.path}`,
      );
    }
  });

  it('uses frame().offset() — never center-based .position()', () => {
    const { files } = specToSwiftUI(KITCHEN_SINK);
    expect(files[1].content).not.toContain('.position(');
    expect(files[1].content).toContain('.offset(x: 24, y: 700)');
  });
});
