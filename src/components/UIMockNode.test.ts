// Covers `sanitizeNodeStyle` — the gatekeeper between Claude-authored
// `node.style` and React's inline-style prop. The contract is narrow but
// load-bearing: any layout-affecting CSS key from runtime JSON has to be
// dropped (coords are the source of truth for layout, mirroring the same
// policy `className` enforces by ignoring `flex`/`grid`/`w-*` Tailwind), and
// every other property has to round-trip verbatim so off-theme color fidelity
// is preserved.

import { describe, expect, it } from 'vitest';
import { sanitizeNodeStyle } from './UIMockNode';

describe('sanitizeNodeStyle', () => {
  it('returns undefined for missing style', () => {
    expect(sanitizeNodeStyle(undefined)).toBeUndefined();
  });

  it('returns undefined when nothing survives the filter', () => {
    expect(sanitizeNodeStyle({ position: 'absolute', top: 0, width: 100 })).toBeUndefined();
  });

  it('preserves color and visual properties verbatim', () => {
    const out = sanitizeNodeStyle({
      backgroundColor: '#0E7C66',
      color: '#ffffff',
      borderColor: '#635BFF',
      boxShadow: '0 8px 32px rgba(99, 91, 255, 0.24)',
      borderRadius: 8,
      opacity: 0.9,
    });
    expect(out).toEqual({
      backgroundColor: '#0E7C66',
      color: '#ffffff',
      borderColor: '#635BFF',
      boxShadow: '0 8px 32px rgba(99, 91, 255, 0.24)',
      borderRadius: 8,
      opacity: 0.9,
    });
  });

  it('preserves gradients and complex backgrounds', () => {
    const out = sanitizeNodeStyle({
      background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)',
    });
    expect(out).toEqual({
      background: 'linear-gradient(135deg, #635BFF 0%, #00D4FF 100%)',
    });
  });

  it('drops positioning keys (coords win for layout)', () => {
    const out = sanitizeNodeStyle({
      position: 'absolute',
      top: 10,
      right: 0,
      bottom: 0,
      left: 20,
      inset: 0,
      backgroundColor: '#fff',
    });
    expect(out).toEqual({ backgroundColor: '#fff' });
  });

  it('drops sizing keys (coords win for layout)', () => {
    const out = sanitizeNodeStyle({
      width: 200,
      height: '50%',
      minWidth: 100,
      maxWidth: 400,
      minHeight: 50,
      maxHeight: 300,
      color: '#000',
    });
    expect(out).toEqual({ color: '#000' });
  });

  it('drops flex/grid/transform keys', () => {
    const out = sanitizeNodeStyle({
      display: 'flex',
      flex: '1 1 auto',
      flexDirection: 'row',
      flexGrow: 1,
      flexShrink: 0,
      grid: 'auto / 1fr 1fr',
      gridTemplateColumns: 'repeat(3, 1fr)',
      transform: 'translate(10px, 0)',
      translate: '10px',
      borderColor: '#abc',
    });
    expect(out).toEqual({ borderColor: '#abc' });
  });

  it('drops null and undefined values', () => {
    const out = sanitizeNodeStyle({
      backgroundColor: '#0E7C66',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      color: null as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      borderColor: undefined as any,
    });
    expect(out).toEqual({ backgroundColor: '#0E7C66' });
  });

  it('passes numeric values through (React accepts both string and number)', () => {
    const out = sanitizeNodeStyle({ borderRadius: 4, opacity: 1, zIndex: 2 });
    expect(out).toEqual({ borderRadius: 4, opacity: 1, zIndex: 2 });
  });
});
