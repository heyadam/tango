import { describe, expect, it } from 'vitest';
import {
  errorTextFromResult,
  extractScreenshotImage,
  isErrorResult,
} from './extractScreenshot';

describe('isErrorResult', () => {
  it('true when isError is true', () => {
    expect(isErrorResult({ isError: true, content: [] })).toBe(true);
  });

  it('false when isError is false', () => {
    expect(isErrorResult({ isError: false, content: [] })).toBe(false);
  });

  it('false when isError is missing', () => {
    expect(isErrorResult({ content: [] })).toBe(false);
  });

  it('false for null / undefined', () => {
    expect(isErrorResult(null)).toBe(false);
    expect(isErrorResult(undefined)).toBe(false);
  });
});

describe('errorTextFromResult', () => {
  it('returns the first text part', () => {
    expect(
      errorTextFromResult({
        isError: true,
        content: [{ type: 'text', text: 'screenshot timeout' }],
      }),
    ).toBe('screenshot timeout');
  });

  it('skips non-text parts to find the message', () => {
    expect(
      errorTextFromResult({
        isError: true,
        content: [
          { type: 'image', data: 'x', mimeType: 'image/png' },
          { type: 'text', text: 'real reason' },
        ],
      }),
    ).toBe('real reason');
  });

  it('falls back to a generic message when there is no text part', () => {
    expect(errorTextFromResult({ isError: true, content: [] })).toMatch(
      /no message/i,
    );
  });

  it('handles null gracefully', () => {
    expect(errorTextFromResult(null)).toMatch(/no message/i);
  });
});

describe('extractScreenshotImage', () => {
  it('pulls data + mimeType out of an image content part', () => {
    expect(
      extractScreenshotImage({
        content: [{ type: 'image', data: 'AAAA', mimeType: 'image/jpeg' }],
      }),
    ).toEqual({ data: 'AAAA', mimeType: 'image/jpeg' });
  });

  it('returns null when isError is true (even if image part present)', () => {
    // Defensive: callers should branch on isError first, but if they don't
    // we shouldn't hand back a stale image part.
    expect(
      extractScreenshotImage({
        isError: true,
        content: [{ type: 'image', data: 'AAAA', mimeType: 'image/jpeg' }],
      }),
    ).toBe(null);
  });

  it('returns null when no image part is present', () => {
    expect(
      extractScreenshotImage({
        content: [{ type: 'text', text: 'hi' }],
      }),
    ).toBe(null);
  });

  it('returns null when content is missing', () => {
    expect(extractScreenshotImage({})).toBe(null);
  });

  it('skips an image part that is missing data', () => {
    expect(
      extractScreenshotImage({
        content: [
          { type: 'image', mimeType: 'image/jpeg' },
          { type: 'text', text: 'noise' },
        ],
      }),
    ).toBe(null);
  });

  it('skips an image part that is missing mimeType', () => {
    expect(
      extractScreenshotImage({
        content: [{ type: 'image', data: 'AAAA' }],
      }),
    ).toBe(null);
  });

  it('returns the first valid image part among mixed content', () => {
    expect(
      extractScreenshotImage({
        content: [
          { type: 'text', text: 'preface' },
          { type: 'image', data: 'first', mimeType: 'image/jpeg' },
          { type: 'image', data: 'second', mimeType: 'image/png' },
        ],
      }),
    ).toEqual({ data: 'first', mimeType: 'image/jpeg' });
  });

  it('returns null for null input', () => {
    expect(extractScreenshotImage(null)).toBe(null);
  });
});
