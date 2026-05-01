import { describe, it, expect } from 'vitest';
import {
  isSafeBundleId,
  isSafeTargetName,
  isSafeUdid,
  parseBuildErrors,
  parseSimctlListBooted,
  pickAppByScheme,
} from './iosBuild';

describe('parseBuildErrors', () => {
  it('returns no errors for clean build output', () => {
    const stdout = [
      'Build settings from command line:',
      'Resolve Package Graph',
      'Resolved source packages:',
      '** BUILD SUCCEEDED **',
      '',
    ].join('\n');
    expect(parseBuildErrors(stdout)).toEqual([]);
  });

  it('extracts a Swift compile error with file:line prefix', () => {
    const stdout = [
      'CompileSwift normal arm64 /tango/ContentView.swift',
      "/tango/ContentView.swift:42:13: error: cannot find 'foo' in scope",
      "/tango/ContentView.swift:42:13: note: did you mean 'food'?",
      '** BUILD FAILED **',
    ].join('\n');
    const errs = parseBuildErrors(stdout);
    expect(errs).toContain(
      "/tango/ContentView.swift:42:13: error: cannot find 'foo' in scope",
    );
    // `note:` lines are not errors
    expect(errs.some((e) => e.includes('note:'))).toBe(false);
  });

  it('extracts ld linker errors', () => {
    const stdout = [
      'Ld /DerivedData/Build/Products/Debug-iphonesimulator/App.app/App',
      'ld: framework not found XYZ',
      "ld: symbol(s) not found for architecture arm64",
      'clang: error: linker command failed with exit code 1',
    ].join('\n');
    const errs = parseBuildErrors(stdout);
    expect(errs).toContain('ld: framework not found XYZ');
    expect(errs).toContain('ld: symbol(s) not found for architecture arm64');
    expect(errs).toContain(
      'clang: error: linker command failed with exit code 1',
    );
  });

  it('extracts xcodebuild scheme errors', () => {
    const stdout = [
      "xcodebuild: error: Scheme 'WrongName' is not currently configured for the build action.",
      '',
    ].join('\n');
    expect(parseBuildErrors(stdout)).toEqual([
      "xcodebuild: error: Scheme 'WrongName' is not currently configured for the build action.",
    ]);
  });

  it('deduplicates repeated error lines', () => {
    const stdout = [
      "/a.swift:1:1: error: duplicate",
      "/a.swift:1:1: error: duplicate",
      "/a.swift:1:1: error: duplicate",
    ].join('\n');
    expect(parseBuildErrors(stdout)).toEqual([
      '/a.swift:1:1: error: duplicate',
    ]);
  });

  it('caps at 20 errors', () => {
    const stdout = Array.from({ length: 50 }, (_, i) =>
      `/file${i}.swift:1:1: error: distinct error ${i}`,
    ).join('\n');
    const errs = parseBuildErrors(stdout);
    expect(errs).toHaveLength(20);
    expect(errs[0]).toContain('distinct error 0');
    expect(errs[19]).toContain('distinct error 19');
  });

  it('ignores warnings and informational lines', () => {
    const stdout = [
      "/a.swift:1:1: warning: deprecated API used",
      'note: building target App',
      '** BUILD SUCCEEDED **',
    ].join('\n');
    expect(parseBuildErrors(stdout)).toEqual([]);
  });
});

describe('parseSimctlListBooted', () => {
  it('returns empty for malformed JSON', () => {
    expect(parseSimctlListBooted('not json')).toEqual([]);
    expect(parseSimctlListBooted('')).toEqual([]);
  });

  it('extracts booted devices across runtimes', () => {
    const json = JSON.stringify({
      devices: {
        'com.apple.CoreSimulator.SimRuntime.iOS-17-0': [
          {
            udid: 'AAA-111',
            name: 'iPhone 15',
            state: 'Booted',
            isAvailable: true,
          },
        ],
        'com.apple.CoreSimulator.SimRuntime.iOS-16-4': [
          {
            udid: 'BBB-222',
            name: 'iPhone 14',
            state: 'Shutdown',
            isAvailable: true,
          },
        ],
      },
    });
    const devices = parseSimctlListBooted(json);
    expect(devices).toHaveLength(1);
    expect(devices[0]).toMatchObject({
      udid: 'AAA-111',
      name: 'iPhone 15',
      state: 'Booted',
    });
  });

  it('ignores devices without a string udid or non-Booted state', () => {
    const json = JSON.stringify({
      devices: {
        'iOS-17-0': [
          { udid: 123, name: 'bogus', state: 'Booted' },
          { name: 'no udid', state: 'Booted' },
          { udid: 'CCC-333', name: 'shutdown', state: 'Shutdown' },
        ],
      },
    });
    expect(parseSimctlListBooted(json)).toEqual([]);
  });

  it('returns empty when devices field is missing', () => {
    expect(parseSimctlListBooted(JSON.stringify({}))).toEqual([]);
    expect(parseSimctlListBooted(JSON.stringify({ devices: null }))).toEqual([]);
  });
});

describe('isSafeUdid', () => {
  it('accepts modern 36-char UUID format', () => {
    expect(isSafeUdid('78D3CDCC-6944-4E77-83AC-686F20529C22')).toBe(true);
  });

  it('accepts older 25/40-char hex formats', () => {
    expect(isSafeUdid('A1B2C3D4E5F60718293A4B5C6D')).toBe(true);
    expect(isSafeUdid('00008101-001A24EE0220001E')).toBe(true);
  });

  it('rejects strings with non-hex characters', () => {
    expect(isSafeUdid('78D3CDCC-XYZ-4E77-83AC-686F20529C22')).toBe(false);
    expect(isSafeUdid('78D3 CDCC-6944')).toBe(false);
    expect(isSafeUdid('78D3CDCC,arch=arm64')).toBe(false);
    expect(isSafeUdid('78D3CDCC" OR "1')).toBe(false);
  });

  it('rejects too-short or too-long input', () => {
    expect(isSafeUdid('ABC')).toBe(false);
    expect(isSafeUdid('A'.repeat(65))).toBe(false);
  });

  it('rejects all-dash strings (no hex content)', () => {
    expect(isSafeUdid('-'.repeat(16))).toBe(false);
    expect(isSafeUdid('-'.repeat(36))).toBe(false);
    expect(isSafeUdid('--------------------------------')).toBe(false);
  });
});

describe('isSafeBundleId', () => {
  it('accepts canonical reverse-DNS bundle ids', () => {
    expect(isSafeBundleId('com.heyadam.tangotestswift')).toBe(true);
    expect(isSafeBundleId('com.example.App-Beta_2')).toBe(true);
  });

  it('rejects bundle ids with predicate-smuggle characters', () => {
    expect(isSafeBundleId('com.example" OR 1==1 OR subsystem == "x')).toBe(false);
    expect(isSafeBundleId('com.example.app\nfoo')).toBe(false);
    expect(isSafeBundleId('com.example.app foo')).toBe(false); // no spaces
    expect(isSafeBundleId('')).toBe(false);
  });
});

describe('isSafeTargetName', () => {
  it('accepts target names with spaces', () => {
    expect(isSafeTargetName('My App')).toBe(true);
    expect(isSafeTargetName('tangotestswift')).toBe(true);
  });

  it('rejects target names with quotes or newlines', () => {
    expect(isSafeTargetName('My"App')).toBe(false);
    expect(isSafeTargetName('App\n')).toBe(false);
    expect(isSafeTargetName('')).toBe(false);
  });
});

describe('pickAppByScheme', () => {
  it('returns null on empty input', () => {
    expect(pickAppByScheme([], 'MyApp')).toBeNull();
  });

  it('prefers exact scheme match over alphabetical first', () => {
    // Without exact-match logic, the alphabetical fallback would pick
    // MyAppExtension.app because it sorts before MyApp.app.
    expect(
      pickAppByScheme(['MyAppExtension.app', 'MyApp.app'], 'MyApp'),
    ).toBe('MyApp.app');
  });

  it('falls back to the first .app when no exact match exists', () => {
    // PRODUCT_NAME override case — the .app got renamed away from the scheme.
    // Caller is then responsible for verifying it is a host app via Info.plist.
    expect(
      pickAppByScheme(['MyApp-Pro.app', 'MyAppWatch.app'], 'MyApp'),
    ).toBe('MyApp-Pro.app');
  });

  it('handles a single-candidate list', () => {
    expect(pickAppByScheme(['Solo.app'], 'Solo')).toBe('Solo.app');
    expect(pickAppByScheme(['Other.app'], 'Solo')).toBe('Other.app');
  });
});
