import { describe, it, expect } from 'vitest';
import { parsePreviewUrl } from './sim';

describe('parsePreviewUrl', () => {
  it('extracts the URL from serve-sim default-mode output', () => {
    const chunk = '\n  - Local:   http://localhost:3200\n  - Network: http://10.0.0.5:3200\n';
    expect(parsePreviewUrl(chunk)).toBe('http://localhost:3200');
  });

  it('handles a higher port when 3200 is taken', () => {
    expect(parsePreviewUrl('  - Local:   http://localhost:3217\n')).toBe(
      'http://localhost:3217',
    );
  });

  it('handles 127.0.0.1 and ::1 loopback hosts', () => {
    expect(parsePreviewUrl('  - Local:   http://127.0.0.1:9000\n')).toBe(
      'http://127.0.0.1:9000',
    );
    expect(parsePreviewUrl('  - Local:   http://[::1]:9000\n')).toBe(
      'http://[::1]:9000',
    );
  });

  it('finds the URL even when the JSON streamer banner appears first', () => {
    const chunk = [
      '{"url":"http://127.0.0.1:3100","streamUrl":"http://127.0.0.1:3100/stream.mjpeg","wsUrl":"ws://127.0.0.1:3100/ws","port":3100,"device":"abc"}',
      '',
      '  - Local:   http://localhost:3201',
      '  - Network: http://10.0.0.5:3201',
      '',
    ].join('\n');
    expect(parsePreviewUrl(chunk)).toBe('http://localhost:3201');
  });

  it('returns null until the line is terminated (chunk-boundary safety)', () => {
    expect(parsePreviewUrl('  - Local:   http://localho')).toBeNull();
    expect(parsePreviewUrl('  - Local:   http://localhost:32')).toBeNull();
    expect(parsePreviewUrl('  - Local:   http://localhost:3200')).toBeNull();
  });

  it('returns null when no banner is present', () => {
    expect(parsePreviewUrl('starting helper...\nconnected\n')).toBeNull();
    expect(parsePreviewUrl('')).toBeNull();
  });

  it('rejects non-loopback hosts (compromised-helper guard)', () => {
    expect(parsePreviewUrl('  - Local:   https://attacker.example/\n')).toBeNull();
    expect(parsePreviewUrl('  - Local:   http://10.0.0.5:3200\n')).toBeNull();
    expect(parsePreviewUrl('  - Local:   http://example.com\n')).toBeNull();
  });

  it('rejects non-http schemes', () => {
    expect(parsePreviewUrl('  - Local:   file:///etc/passwd\n')).toBeNull();
    expect(parsePreviewUrl('  - Local:   javascript:alert(1)\n')).toBeNull();
  });

  it('rejects malformed URLs', () => {
    expect(parsePreviewUrl('  - Local:   http://\n')).toBeNull();
  });
});
