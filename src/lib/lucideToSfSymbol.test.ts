import { describe, expect, it } from 'vitest';
import { SF_SYMBOL_FALLBACK, lucideToSfSymbol } from './lucideToSfSymbol';

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
