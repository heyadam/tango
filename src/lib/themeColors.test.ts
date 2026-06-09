import { describe, expect, it } from 'vitest';
import {
  TANGO_THEME,
  oklchToRgba,
  parseCssColor,
  parseLinearGradient,
  withAlpha,
} from './themeColors';

describe('oklchToRgba', () => {
  it('converts the achromatic anchors exactly', () => {
    expect(oklchToRgba(1, 0, 0)).toEqual({ r: 255, g: 255, b: 255, a: 1 });
    expect(oklchToRgba(0, 0, 0)).toEqual({ r: 0, g: 0, b: 0, a: 1 });
  });

  it('keeps zero-chroma colors gray (r = g = b)', () => {
    const { r, g, b } = oklchToRgba(0.5, 0, 0);
    expect(r).toBe(g);
    expect(g).toBe(b);
  });

  it('carries alpha through', () => {
    expect(oklchToRgba(1, 0, 0, 0.5).a).toBe(0.5);
  });

  it('pins the brand palette conversions (regression goldens)', () => {
    expect(TANGO_THEME.primary).toEqual({ r: 97, g: 89, b: 225, a: 1 }); // purple
    expect(TANGO_THEME.background).toEqual({ r: 245, g: 238, b: 224, a: 1 }); // cream
    expect(TANGO_THEME.foreground).toEqual({ r: 10, g: 18, b: 53, a: 1 }); // navy
    expect(TANGO_THEME.secondary).toEqual({ r: 139, g: 210, b: 185, a: 1 }); // mint
    expect(TANGO_THEME.destructive).toEqual({ r: 241, g: 73, b: 141, a: 1 });
  });

  it('clamps out-of-gamut channels into 0–255', () => {
    const c = oklchToRgba(0.7, 0.4, 145); // hyper-saturated green
    for (const v of [c.r, c.g, c.b]) {
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThanOrEqual(255);
    }
  });
});

describe('parseCssColor', () => {
  it('parses #rrggbb and #rgb', () => {
    expect(parseCssColor('#0E7C66')).toEqual({ r: 14, g: 124, b: 102, a: 1 });
    expect(parseCssColor('#fff')).toEqual({ r: 255, g: 255, b: 255, a: 1 });
  });

  it('parses #rrggbbaa', () => {
    const c = parseCssColor('#ff000080');
    expect(c).not.toBeNull();
    expect(c!.r).toBe(255);
    expect(c!.a).toBeCloseTo(0.5, 1);
  });

  it('parses rgb()/rgba() in comma and space syntax', () => {
    expect(parseCssColor('rgb(1, 2, 3)')).toEqual({ r: 1, g: 2, b: 3, a: 1 });
    expect(parseCssColor('rgba(1, 2, 3, 0.4)')).toEqual({ r: 1, g: 2, b: 3, a: 0.4 });
    expect(parseCssColor('rgb(1 2 3 / 0.4)')).toEqual({ r: 1, g: 2, b: 3, a: 0.4 });
  });

  it('parses oklch() with optional alpha', () => {
    expect(parseCssColor('oklch(1 0 0)')).toEqual({ r: 255, g: 255, b: 255, a: 1 });
    expect(parseCssColor('oklch(0.55 0.20 280 / 0.5)')!.a).toBe(0.5);
  });

  it('parses named colors and transparent', () => {
    expect(parseCssColor('white')).toEqual({ r: 255, g: 255, b: 255, a: 1 });
    expect(parseCssColor('transparent')!.a).toBe(0);
  });

  it('returns null for unparseable values', () => {
    expect(parseCssColor('var(--foreground)')).toBeNull();
    expect(parseCssColor('hotmess')).toBeNull();
    expect(parseCssColor('#zz0011')).toBeNull();
  });
});

describe('withAlpha', () => {
  it('overrides only alpha', () => {
    expect(withAlpha({ r: 1, g: 2, b: 3, a: 1 }, 0.3)).toEqual({ r: 1, g: 2, b: 3, a: 0.3 });
  });
});

describe('parseLinearGradient', () => {
  it('parses angle + hex stops with positions', () => {
    const g = parseLinearGradient('linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)');
    expect(g).not.toBeNull();
    expect(g!.angleDeg).toBe(135);
    expect(g!.stops).toHaveLength(2);
    expect(g!.stops[0]).toEqual({ color: { r: 99, g: 91, b: 255, a: 1 }, at: 0 });
    expect(g!.stops[1].at).toBe(1);
  });

  it('defaults missing positions to an even spread', () => {
    const g = parseLinearGradient('linear-gradient(90deg, #000, #888, #fff)');
    expect(g!.stops.map((s) => s.at)).toEqual([0, 0.5, 1]);
  });

  it('maps side keywords to angles and defaults to "to bottom"', () => {
    expect(parseLinearGradient('linear-gradient(to right, #000, #fff)')!.angleDeg).toBe(90);
    expect(parseLinearGradient('linear-gradient(#000, #fff)')!.angleDeg).toBe(180);
  });

  it('handles rgba() stops (top-level comma splitting)', () => {
    const g = parseLinearGradient('linear-gradient(45deg, rgba(0, 0, 0, 0.5), rgb(255, 255, 255))');
    expect(g!.stops[0].color.a).toBe(0.5);
  });

  it('returns null for non-gradients and single-stop input', () => {
    expect(parseLinearGradient('#fff')).toBeNull();
    expect(parseLinearGradient('linear-gradient(90deg, #fff)')).toBeNull();
    expect(parseLinearGradient('radial-gradient(#000, #fff)')).toBeNull();
  });
});
