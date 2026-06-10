import { describe, expect, it } from 'vitest';
import {
  applyFill,
  applyFillColor,
  applyFontWeight,
  applyRadius,
  applyStrokeColor,
  applyStrokeColorHex,
  applyStrokeWidth,
  applyTextAlign,
  applyTextColor,
  hasClass,
  setStyleKey,
  swapClassToken,
} from './classTokens';
import type { UINode } from './uiMockProtocol';

function node(partial: Partial<UINode>): UINode {
  return { id: 'n1', type: 'rect', x: 0, y: 0, width: 100, height: 80, ...partial };
}

describe('swapClassToken', () => {
  it('replaces only the matching family, preserving order of the rest', () => {
    expect(swapClassToken('bg-muted rounded-lg shadow-md', /^bg-/, 'bg-primary')).toBe(
      'rounded-lg shadow-md bg-primary',
    );
  });

  it('removes the family when replacement is null', () => {
    expect(swapClassToken('bg-muted rounded-lg', /^rounded(-.+)?$/, null)).toBe('bg-muted');
  });

  it('returns undefined when nothing is left', () => {
    expect(swapClassToken('bg-muted', /^bg-/, null)).toBeUndefined();
    expect(swapClassToken(undefined, /^bg-/, null)).toBeUndefined();
  });
});

describe('applyFill', () => {
  it('swaps bg classes and strips inline background overrides', () => {
    const p = applyFill(
      node({ className: 'bg-muted/50 border-2', style: { backgroundColor: '#ff0000', opacity: 0.5 } }),
      'primary',
    );
    expect(p.className).toBe('border-2 bg-primary');
    expect(p.style).toEqual({ opacity: 0.5 });
  });

  it('null token means transparent (explicit none)', () => {
    expect(applyFill(node({}), null).className).toBe('bg-transparent');
  });

  it('clears style to undefined when the only key was background', () => {
    const p = applyFill(node({ style: { background: 'linear-gradient(#fff, #000)' } }), 'muted');
    expect(p.style).toBeUndefined();
    // The key must still be present so the shallow merge clears it.
    expect('style' in p).toBe(true);
  });
});

describe('applyStrokeColor', () => {
  it('replaces border color classes but keeps width and dash', () => {
    const p = applyStrokeColor(
      node({ className: 'border-2 border-dashed border-muted/60' }),
      'destructive',
    );
    expect(p.className).toBe('border-2 border-dashed border-destructive');
  });

  it('leaves bare border (width family) alone', () => {
    const p = applyStrokeColor(node({ className: 'border' }), 'primary');
    expect(p.className).toBe('border border-primary');
  });
});

describe('applyStrokeWidth', () => {
  it('replaces border-N and bare border', () => {
    expect(applyStrokeWidth(node({ className: 'border border-primary' }), 4).className).toBe(
      'border-primary border-4',
    );
    expect(applyStrokeWidth(node({ className: 'border-2' }), 0).className).toBe('border-0');
  });
});

describe('applyRadius', () => {
  it('replaces any rounded-* class', () => {
    expect(applyRadius(node({ className: 'bg-muted rounded-full' }), 'rounded-md').className).toBe(
      'bg-muted rounded-md',
    );
    expect(applyRadius(node({ className: 'bg-muted rounded-md' }), null).className).toBe('bg-muted');
  });
});

describe('hasClass', () => {
  it('matches whole class names only', () => {
    const n = node({ className: 'bg-primary rounded-md' });
    expect(hasClass(n, 'bg-primary')).toBe(true);
    expect(hasClass(n, 'bg-prim')).toBe(false);
    expect(hasClass(node({}), 'bg-primary')).toBe(false);
  });
});

describe('applyTextColor', () => {
  it('swaps color utilities but spares sizes and alignment', () => {
    const p = applyTextColor(
      node({ className: 'text-sm text-center text-muted-foreground', style: { color: '#333' } }),
      'destructive',
    );
    expect(p.className).toBe('text-sm text-center text-destructive');
    expect(p.style).toBeUndefined();
  });
});

describe('applyTextAlign / applyFontWeight', () => {
  it('replaces only their families', () => {
    expect(applyTextAlign(node({ className: 'text-sm text-left' }), 'right').className).toBe(
      'text-sm text-right',
    );
    expect(applyFontWeight(node({ className: 'font-serif font-bold' }), 'font-medium').className).toBe(
      'font-serif font-medium',
    );
    expect(applyFontWeight(node({ className: 'font-bold' }), null).className).toBeUndefined();
  });
});

describe('setStyleKey', () => {
  it('sets, overwrites, and clears one key', () => {
    expect(setStyleKey(node({}), 'opacity', 0.5).style).toEqual({ opacity: 0.5 });
    expect(
      setStyleKey(node({ style: { opacity: 0.5, color: '#fff' } }), 'opacity', 0.8).style,
    ).toEqual({ color: '#fff', opacity: 0.8 });
    expect(
      setStyleKey(node({ style: { opacity: 0.5 } }), 'opacity', null).style,
    ).toBeUndefined();
  });
});

describe('applyFillColor / applyStrokeColorHex', () => {
  it('moves the channel to inline style and clears token classes', () => {
    const fill = applyFillColor(node({ className: 'bg-muted rounded-md' }), '#0E7C66');
    expect(fill.className).toBe('rounded-md');
    expect(fill.style).toEqual({ backgroundColor: '#0E7C66' });

    const stroke = applyStrokeColorHex(
      node({ className: 'border-2 border-primary border-dashed' }),
      '#FF00AA',
    );
    expect(stroke.className).toBe('border-2 border-dashed');
    expect(stroke.style).toEqual({ borderColor: '#FF00AA' });
  });
});
