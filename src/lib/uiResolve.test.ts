import { describe, expect, it } from 'vitest';
import { TANGO_THEME, withAlpha } from './themeColors';
import { resolveNode, resolveNodeStyle, resolveSpec } from './uiResolve';
import type { UINode, UISpec } from './uiMockProtocol';

function node(partial: Partial<UINode> & Pick<UINode, 'type'>): UINode {
  return {
    id: 'n1',
    x: 10,
    y: 20,
    width: 100,
    height: 40,
    ...partial,
  };
}

describe('baselines per kind', () => {
  it('div → dashed muted box', () => {
    const s = resolveNodeStyle(node({ type: 'div' }));
    expect(s.backgroundColor).toEqual(withAlpha(TANGO_THEME.muted, 0.3));
    expect(s.borderDashed).toBe(true);
    expect(s.borderWidth).toBe(1);
    expect(s.cornerRadius).toBe(8);
  });

  it('text → 14px foreground', () => {
    const s = resolveNodeStyle(node({ type: 'text' }));
    expect(s.fontSize).toBe(14);
    expect(s.textColor).toEqual(TANGO_THEME.foreground);
  });

  it('heading folds level into serif size/weight', () => {
    const h1 = resolveNodeStyle(node({ type: 'heading', props: { level: 1 } }));
    expect(h1.fontFamily).toBe('serif');
    expect(h1.fontSize).toBe(30);
    expect(h1.fontWeight).toBe(700);
    const h3 = resolveNodeStyle(node({ type: 'heading', props: { level: 3 } }));
    expect(h3.fontSize).toBe(18);
    expect(h3.fontWeight).toBe(600);
    // default level is 2
    const h = resolveNodeStyle(node({ type: 'heading' }));
    expect(h.fontSize).toBe(24);
  });

  it('Button default → primary bg, centered, rounded-md', () => {
    const s = resolveNodeStyle(node({ type: 'Button' }));
    expect(s.backgroundColor).toEqual(TANGO_THEME.primary);
    expect(s.textColor).toEqual(TANGO_THEME['primary-foreground']);
    expect(s.textAlign).toBe('center');
    expect(s.cornerRadius).toBe(8);
    expect(s.fontWeight).toBe(500);
  });

  it('Button variants map to their token pairs', () => {
    const outline = resolveNodeStyle(node({ type: 'Button', props: { variant: 'outline' } }));
    expect(outline.backgroundColor).toEqual(TANGO_THEME.background);
    expect(outline.borderWidth).toBe(1);
    const ghost = resolveNodeStyle(node({ type: 'Button', props: { variant: 'ghost' } }));
    expect(ghost.backgroundColor!.a).toBe(0);
    const destructive = resolveNodeStyle(node({ type: 'Button', props: { variant: 'destructive' } }));
    expect(destructive.backgroundColor).toEqual(TANGO_THEME.destructive);
  });

  it('Badge → pill radius, 12px', () => {
    const s = resolveNodeStyle(node({ type: 'Badge' }));
    expect(s.cornerRadius).toBe(9999);
    expect(s.fontSize).toBe(12);
  });

  it('Input → input border + muted placeholder color', () => {
    const s = resolveNodeStyle(node({ type: 'Input' }));
    expect(s.borderColor).toEqual(TANGO_THEME.input);
    expect(s.textColor).toEqual(TANGO_THEME['muted-foreground']);
  });

  it('Separator → border color fill', () => {
    const s = resolveNodeStyle(node({ type: 'Separator' }));
    expect(s.backgroundColor).toEqual(TANGO_THEME.border);
  });

  it('Icon → foreground tint', () => {
    const s = resolveNodeStyle(node({ type: 'Icon' }));
    expect(s.textColor).toEqual(TANGO_THEME.foreground);
  });
});

describe('className overlay', () => {
  it('theme color utilities override the baseline', () => {
    const s = resolveNodeStyle(node({ type: 'div', className: 'bg-card text-muted-foreground' }));
    expect(s.backgroundColor).toEqual(TANGO_THEME.card);
    expect(s.textColor).toEqual(TANGO_THEME['muted-foreground']);
  });

  it('supports /NN opacity suffixes', () => {
    const s = resolveNodeStyle(node({ type: 'div', className: 'bg-primary/50 border-border/60' }));
    expect(s.backgroundColor).toEqual(withAlpha(TANGO_THEME.primary, 0.5));
    expect(s.borderColor).toEqual(withAlpha(TANGO_THEME.border, 0.6));
  });

  it('parses typography, radius, border, shadow, opacity, padding', () => {
    const s = resolveNodeStyle(
      node({
        type: 'div',
        className:
          'text-lg font-semibold italic font-mono rounded-xl border-2 shadow-md opacity-80 px-4 py-2 text-center',
      }),
    );
    expect(s.fontSize).toBe(18);
    expect(s.fontWeight).toBe(600);
    expect(s.italic).toBe(true);
    expect(s.fontFamily).toBe('mono');
    expect(s.cornerRadius).toBe(14);
    expect(s.borderWidth).toBe(2);
    expect(s.shadow).toEqual({ radius: 6, y: 4, alpha: 0.1 });
    expect(s.opacity).toBe(0.8);
    expect(s.padding).toEqual({ top: 8, right: 16, bottom: 8, left: 16 });
    expect(s.textAlign).toBe('center');
  });

  it('ignores layout and unknown classes', () => {
    const base = resolveNodeStyle(node({ type: 'text' }));
    const s = resolveNodeStyle(
      node({ type: 'text', className: 'flex w-full h-full grid-cols-3 backdrop-blur whatever-9000' }),
    );
    expect(s).toEqual(base);
  });

  it('bare `border` defaults to 1px theme border color', () => {
    const s = resolveNodeStyle(node({ type: 'text', className: 'border' }));
    expect(s.borderWidth).toBe(1);
    expect(s.borderColor).toEqual(TANGO_THEME.border);
  });

  it('white/black/transparent literals work', () => {
    const s = resolveNodeStyle(node({ type: 'div', className: 'bg-white text-black' }));
    expect(s.backgroundColor).toEqual({ r: 255, g: 255, b: 255, a: 1 });
    expect(s.textColor).toEqual({ r: 0, g: 0, b: 0, a: 1 });
  });
});

describe('inline style overlay (off-theme channel)', () => {
  it('beats both baseline and className', () => {
    const s = resolveNodeStyle(
      node({
        type: 'Button',
        className: 'bg-secondary',
        style: { backgroundColor: '#0E7C66', color: '#ffffff' },
      }),
    );
    expect(s.backgroundColor).toEqual({ r: 14, g: 124, b: 102, a: 1 });
    expect(s.textColor).toEqual({ r: 255, g: 255, b: 255, a: 1 });
  });

  it('parses gradients out of `background` and clears solid bg', () => {
    const s = resolveNodeStyle(
      node({
        type: 'div',
        style: { background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)' },
      }),
    );
    expect(s.gradient).not.toBeUndefined();
    expect(s.gradient!.angleDeg).toBe(135);
    expect(s.backgroundColor).toBeUndefined();
  });

  it('a later solid background replaces a gradient', () => {
    const s = resolveNodeStyle(
      node({ type: 'div', style: { background: '#123456' } }),
    );
    expect(s.gradient).toBeUndefined();
    expect(s.backgroundColor).toEqual({ r: 0x12, g: 0x34, b: 0x56, a: 1 });
  });

  it('parses numeric and px-string dimensions', () => {
    const s = resolveNodeStyle(
      node({
        type: 'div',
        style: { borderRadius: '16px', fontSize: 22, borderWidth: 2, borderColor: '#635BFF' },
      }),
    );
    expect(s.cornerRadius).toBe(16);
    expect(s.fontSize).toBe(22);
    expect(s.borderWidth).toBe(2);
    expect(s.borderColor).toEqual({ r: 99, g: 91, b: 255, a: 1 });
  });

  it('parses padding shorthands', () => {
    expect(resolveNodeStyle(node({ type: 'div', style: { padding: 8 } })).padding)
      .toEqual({ top: 8, right: 8, bottom: 8, left: 8 });
    expect(resolveNodeStyle(node({ type: 'div', style: { padding: '4px 8px' } })).padding)
      .toEqual({ top: 4, right: 8, bottom: 4, left: 8 });
  });

  it('parses boxShadow best-effort', () => {
    const s = resolveNodeStyle(
      node({ type: 'div', style: { boxShadow: '0 8px 32px rgba(99, 91, 255, 0.24)' } }),
    );
    expect(s.shadow).toEqual({ radius: 32, y: 8, alpha: 0.24 });
  });

  it('ignores unparseable values without dropping the rest', () => {
    const s = resolveNodeStyle(
      node({ type: 'text', style: { color: 'var(--foreground)', fontSize: 20 } }),
    );
    expect(s.textColor).toEqual(TANGO_THEME.foreground); // baseline kept
    expect(s.fontSize).toBe(20);
  });
});

describe('resolveNode content mapping', () => {
  it('maps kinds and carries geometry', () => {
    const r = resolveNode(node({ type: 'div', x: 1, y: 2, width: 3, height: 4 }));
    expect(r.kind).toBe('box');
    expect([r.x, r.y, r.width, r.height]).toEqual([1, 2, 3, 4]);
  });

  it('Button/Badge default their labels like the web renderer', () => {
    expect(resolveNode(node({ type: 'Button' })).text).toBe('Button');
    expect(resolveNode(node({ type: 'Badge' })).text).toBe('Badge');
  });

  it('Input placeholder comes from props, then text, then default — flagged', () => {
    const fromProps = resolveNode(node({ type: 'Input', props: { placeholder: 'Email' } }));
    expect(fromProps.text).toBe('Email');
    expect(fromProps.isPlaceholderText).toBe(true);
    expect(resolveNode(node({ type: 'Input', text: 'Name' })).text).toBe('Name');
    expect(resolveNode(node({ type: 'Input' })).text).toBe('Placeholder');
  });

  it('Image keeps http(s) srcs only', () => {
    expect(resolveNode(node({ type: 'Image', props: { src: 'https://x.test/a.png' } })).imageSrc)
      .toBe('https://x.test/a.png');
    expect(resolveNode(node({ type: 'Image', props: { src: 'data:image/png;base64,xx' } })).imageSrc)
      .toBeUndefined();
    expect(resolveNode(node({ type: 'Image' })).imageSrc).toBeUndefined();
  });

  it('Icon resolves an SF Symbol name', () => {
    expect(resolveNode(node({ type: 'Icon', props: { iconName: 'Search' } })).sfSymbol)
      .toBe('magnifyingglass');
  });

  it('Separator carries orientation', () => {
    expect(resolveNode(node({ type: 'Separator', props: { orientation: 'vertical' } })).separatorVertical)
      .toBe(true);
    expect(resolveNode(node({ type: 'Separator' })).separatorVertical).toBe(false);
  });
});

describe('resolveSpec', () => {
  it('resolves every screen and node, preserving order', () => {
    const spec: UISpec = {
      screens: [
        {
          id: 'login',
          title: 'Login',
          frame: { w: 390, h: 844 },
          nodes: [
            node({ id: 'a', type: 'heading', text: 'Welcome' }),
            node({ id: 'b', type: 'Button', text: 'Sign in' }),
          ],
        },
      ],
    };
    const r = resolveSpec(spec);
    expect(r.version).toBe(1);
    expect(r.screens).toHaveLength(1);
    expect(r.screens[0].frame).toEqual({ w: 390, h: 844 });
    expect(r.screens[0].nodes.map((n) => n.id)).toEqual(['a', 'b']);
  });
});
