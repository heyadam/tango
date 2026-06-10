import { describe, expect, it } from 'vitest';
import {
  SF_SYMBOL_FALLBACK,
  lucideToSfSymbol,
  sfSymbolToLucide,
} from './lucideToSfSymbol';

describe('lucideToSfSymbol', () => {
  it('maps common lucide names', () => {
    expect(lucideToSfSymbol('Search')).toBe('magnifyingglass');
    expect(lucideToSfSymbol('Trash2')).toBe('trash');
    expect(lucideToSfSymbol('ChevronRight')).toBe('chevron.right');
    expect(lucideToSfSymbol('Home')).toBe('house');
  });

  it('returns a visible placeholder for unmapped names', () => {
    expect(lucideToSfSymbol('SomeObscureIcon')).toBe(SF_SYMBOL_FALLBACK);
  });

  it('mirrors the web renderer Circle default when no name is given', () => {
    expect(lucideToSfSymbol(null)).toBe('circle');
    expect(lucideToSfSymbol(undefined)).toBe('circle');
    expect(lucideToSfSymbol('')).toBe('circle');
  });
});

describe('sfSymbolToLucide', () => {
  it('reverses unambiguous mappings', () => {
    expect(sfSymbolToLucide('magnifyingglass')).toBe('Search');
    expect(sfSymbolToLucide('chevron.right')).toBe('ChevronRight');
    expect(sfSymbolToLucide('bell')).toBe('Bell');
  });

  it('resolves many-to-one collisions to curated canonical names', () => {
    expect(sfSymbolToLucide('ellipsis')).toBe('MoreHorizontal');
    expect(sfSymbolToLucide('trash')).toBe('Trash2');
    expect(sfSymbolToLucide('pencil')).toBe('Pencil');
    expect(sfSymbolToLucide('message')).toBe('MessageCircle');
    expect(sfSymbolToLucide('house')).toBe('Home');
  });

  it('retries variant suffixes bare', () => {
    expect(sfSymbolToLucide('star.fill')).toBe('Star');
    expect(sfSymbolToLucide('heart.fill')).toBe('Heart');
  });

  it('returns null for unrepresentable symbols', () => {
    expect(sfSymbolToLucide('figure.indoor.cycle')).toBeNull();
  });

  it('round-trips through the forward map', () => {
    for (const name of ['Search', 'Star', 'Bell', 'Calendar', 'Lock']) {
      expect(sfSymbolToLucide(lucideToSfSymbol(name))).toBe(name);
    }
  });
});
