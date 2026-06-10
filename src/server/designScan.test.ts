import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  aggregateDesignScan,
  designScanKickoffBlock,
  findAssetColors,
  parseColorsetJson,
  rgbaToHex,
  runDesignScan,
  scanSwiftSource,
} from './designScan';

describe('rgbaToHex', () => {
  it('formats opaque colors as #RRGGBB', () => {
    expect(rgbaToHex(255, 0, 128)).toBe('#FF0080');
  });

  it('appends the alpha byte only when translucent', () => {
    expect(rgbaToHex(0, 0, 0, 0.5)).toBe('#00000080');
    expect(rgbaToHex(0, 0, 0, 1)).toBe('#000000');
  });
});

describe('parseColorsetJson', () => {
  it('parses float components', () => {
    const raw = JSON.stringify({
      colors: [
        {
          color: {
            'color-space': 'srgb',
            components: { red: '1.000', green: '0.502', blue: '0.000', alpha: '1.000' },
          },
          idiom: 'universal',
        },
      ],
    });
    expect(parseColorsetJson('BrandOrange', raw)).toEqual({
      name: 'BrandOrange',
      value: '#FF8000',
    });
  });

  it('parses 0x hex and integer components', () => {
    const raw = JSON.stringify({
      colors: [
        {
          color: { components: { red: '0x61', green: '89', blue: '0xE1', alpha: '1' } },
        },
      ],
    });
    expect(parseColorsetJson('Primary', raw)?.value).toBe('#6159E1');
  });

  it('prefers the any/light entry over dark appearances', () => {
    const raw = JSON.stringify({
      colors: [
        {
          appearances: [{ appearance: 'luminosity', value: 'dark' }],
          color: { components: { red: '0.0', green: '0.0', blue: '0.0', alpha: '1' } },
        },
        {
          color: { components: { red: '1.0', green: '1.0', blue: '1.0', alpha: '1' } },
        },
      ],
    });
    expect(parseColorsetJson('Surface', raw)?.value).toBe('#FFFFFF');
  });

  it('returns null on malformed input', () => {
    expect(parseColorsetJson('x', 'not json')).toBeNull();
    expect(parseColorsetJson('x', '{}')).toBeNull();
    expect(parseColorsetJson('x', JSON.stringify({ colors: [{}] }))).toBeNull();
    expect(
      parseColorsetJson(
        'x',
        JSON.stringify({ colors: [{ color: { components: { red: '9.5' } } }] }),
      ),
    ).toBeNull();
  });
});

describe('scanSwiftSource', () => {
  it('extracts literal colors with declared names', () => {
    const scan = scanSwiftSource(
      [
        'static let brandGreen = Color(red: 0.05, green: 0.49, blue: 0.4)',
        'Color(red: 0.05, green: 0.49, blue: 0.4)',
        'let surface = Color(hex: 0xF5EEE0)',
        'Color("AccentColor")',
        '#colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)',
      ].join('\n'),
    );
    const hex = rgbaToHex(13, 125, 102);
    expect(scan.colorHexes.get(hex)).toBe(2);
    expect(scan.colorNames.get(hex)).toBe('brandGreen');
    expect(scan.colorHexes.get('#F5EEE0')).toBe(1);
    expect(scan.colorNames.get('#F5EEE0')).toBe('surface');
    expect(scan.namedColorRefs.get('AccentColor')).toBe(1);
    expect(scan.colorHexes.get('#FF0000')).toBe(1);
  });

  it('extracts typography (system, builtin, custom)', () => {
    const scan = scanSwiftSource(
      [
        'Text("a").font(.system(size: 17, weight: .semibold))',
        'Text("b").font(.headline)',
        'Text("c").font(.custom("Inter", size: 14))',
      ].join('\n'),
    );
    const keys = [...scan.typeStyles.keys()];
    expect(keys).toContain(JSON.stringify(['system-17-semibold', 17, 600, null]));
    expect(keys).toContain(JSON.stringify(['headline', 17, 600, null]));
    expect(keys).toContain(JSON.stringify(['Inter-14', 14, null, 'Inter']));
  });

  it('extracts spacing, radii, icons, and shadows', () => {
    const scan = scanSwiftSource(
      [
        'VStack(spacing: 12) {',
        '.padding(16)',
        '.padding(.horizontal, 16)',
        'RoundedRectangle(cornerRadius: 12)',
        '.cornerRadius(8)',
        'Image(systemName: "magnifyingglass")',
        'Label("Set", systemImage: "gearshape")',
        '.shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)',
      ].join('\n'),
    );
    expect(scan.spacings.get('12')).toBe(1);
    expect(scan.spacings.get('16')).toBe(2);
    expect(scan.radii.get('12')).toBe(1);
    expect(scan.radii.get('8')).toBe(1);
    expect(scan.sfSymbols.get('magnifyingglass')).toBe(1);
    expect(scan.shadows.get('radius 8, x 0, y 2')).toBe(1);
  });

  it('finds View struct declarations and ignores comments', () => {
    const scan = scanSwiftSource(
      [
        'struct TaskRow: View {',
        'struct Generic<T>: View {',
        'struct Helper: Equatable, View {',
        '// struct CommentedOut: View',
        'struct NotAView: Equatable {',
      ].join('\n'),
    );
    expect(scan.viewStructs).toEqual(['TaskRow', 'Generic', 'Helper']);
  });

  it('ignores block-commented code, including across lines', () => {
    const scan = scanSwiftSource(
      [
        '/* struct OldRow: View {',
        '   Color(red: 1, green: 0, blue: 0)',
        '*/ struct LiveRow: View {',
        'let x = 1 /* .padding(99) */ + 2',
      ].join('\n'),
    );
    expect(scan.viewStructs).toEqual(['LiveRow']);
    expect(scan.colorHexes.size).toBe(0);
    expect(scan.spacings.size).toBe(0);
  });

  it('attributes a declared name to the color at the decl init, not the first match', () => {
    const scan = scanSwiftSource(
      'let surface = Color(hex: 0xF5EEE0); Color(red: 1, green: 0, blue: 0)',
    );
    expect(scan.colorNames.get('#F5EEE0')).toBe('surface');
    expect(scan.colorNames.has('#FF0000')).toBe(false);
  });

  it('skips ambiguous 8-digit hex literals but accepts trailing-FF ones', () => {
    const scan = scanSwiftSource(
      ['Color(hex: 0x6159E1FF)', 'Color(hex: 0x806159E1)'].join('\n'),
    );
    expect(scan.colorHexes.get('#6159E1')).toBe(1);
    expect(scan.colorHexes.size).toBe(1);
  });

  it('merges integer and dotted spellings of the same value', () => {
    const scan = scanSwiftSource(
      ['.padding(8)', '.padding(8.0)', 'VStack(spacing: 8) {'].join('\n'),
    );
    expect(scan.spacings.get('8')).toBe(3);
    expect(scan.spacings.size).toBe(1);
  });
});

describe('aggregateDesignScan', () => {
  const fileOf = (relPath: string, content: string) => ({
    relPath,
    content,
    scan: scanSwiftSource(content),
  });

  it('merges counts, names asset colors, maps icons, ranks candidates', () => {
    const row = [
      'struct TaskRow: View {',
      'Image(systemName: "star.fill")',
      '.padding(16)',
    ].join('\n');
    const screenA = [
      'struct HomeView: View {',
      'TaskRow()',
      'Color("Brand")',
      '.padding(16)',
    ].join('\n');
    const screenB = ['struct DetailView: View {', 'TaskRow()'].join('\n');
    const result = aggregateDesignScan(
      [fileOf('A/TaskRow.swift', row), fileOf('A/HomeView.swift', screenA), fileOf('A/DetailView.swift', screenB)],
      [{ name: 'Brand', value: '#6159E1' }],
    );
    expect(result.designSystem.colors).toEqual([
      { name: 'Brand', value: '#6159E1', count: 1 },
    ]);
    expect(result.designSystem.spacing).toEqual([16]);
    expect(result.designSystem.icons).toEqual(['Star']);
    expect(result.componentCandidates[0]).toEqual({
      name: 'TaskRow',
      declaredIn: 'A/TaskRow.swift',
      referencedByFiles: 2,
    });
  });

  it('is deterministic and capped', () => {
    const lines: string[] = [];
    for (let i = 0; i < 30; i++) {
      const ch = (i * 7) % 100 / 100;
      lines.push(`Color(red: ${ch}, green: 0.5, blue: 0.5)`);
    }
    const result = aggregateDesignScan([fileOf('X.swift', lines.join('\n'))], []);
    expect(result.designSystem.colors!.length).toBeLessThanOrEqual(16);
    const again = aggregateDesignScan([fileOf('X.swift', lines.join('\n'))], []);
    expect(again).toEqual(result);
  });

  it('returns an empty design system for token-free sources', () => {
    const result = aggregateDesignScan(
      [fileOf('Model.swift', 'struct User { let id: Int }')],
      [],
    );
    expect(result.designSystem).toEqual({});
    expect(result.componentCandidates).toEqual([]);
  });

  it('caps the COMBINED color list even when asset catalogs alone exceed it', () => {
    const assets = Array.from({ length: 30 }, (_, i) => ({
      name: `Asset${String(i).padStart(2, '0')}`,
      value: '#111111',
    }));
    const result = aggregateDesignScan(
      [fileOf('A.swift', 'Color(red: 0.5, green: 0.5, blue: 0.5)')],
      assets,
    );
    expect(result.designSystem.colors!.length).toBeLessThanOrEqual(16);
  });

  it('keeps the most-referenced asset colors when capping', () => {
    const assets = Array.from({ length: 20 }, (_, i) => ({
      name: `Asset${String(i).padStart(2, '0')}`,
      value: '#111111',
    }));
    const result = aggregateDesignScan(
      [fileOf('A.swift', 'Color("Asset19")\nColor("Asset19")')],
      assets,
    );
    expect(result.designSystem.colors![0]).toEqual({
      name: 'Asset19',
      value: '#111111',
      count: 2,
    });
  });

  it('does not count string-literal or comment mentions as component references', () => {
    const result = aggregateDesignScan(
      [
        fileOf('Settings.swift', 'struct Settings: View {'),
        fileOf('A.swift', 'Text("Settings")\n.navigationTitle("Settings")'),
        fileOf('B.swift', '// Settings is configured here'),
        fileOf('C.swift', 'Settings()'),
      ],
      [],
    );
    expect(result.componentCandidates).toEqual([
      { name: 'Settings', declaredIn: 'Settings.swift', referencedByFiles: 1 },
    ]);
  });
});

describe('designScanKickoffBlock', () => {
  it('lists tokens and reusable candidates, skips zero-ref structs', () => {
    const block = designScanKickoffBlock({
      designSystem: {
        colors: [{ name: 'Brand', value: '#6159E1', count: 3 }],
        spacing: [16, 8],
        icons: ['Star'],
      },
      componentCandidates: [
        { name: 'TaskRow', declaredIn: 'A.swift', referencedByFiles: 2 },
        { name: 'HomeView', declaredIn: 'B.swift', referencedByFiles: 0 },
      ],
    });
    expect(block).toContain('Brand #6159E1 ×3');
    expect(block).toContain('Spacing: 16, 8');
    expect(block).toContain('TaskRow (A.swift, 2)');
    expect(block).not.toContain('HomeView');
  });

  it('returns empty string when there is nothing to report', () => {
    expect(
      designScanKickoffBlock({ designSystem: {}, componentCandidates: [] }),
    ).toBe('');
  });

  it("scopes the 'stored' claim to tokens — candidates-only scans never claim storage", () => {
    const candidatesOnly = designScanKickoffBlock({
      designSystem: {},
      componentCandidates: [
        { name: 'TaskRow', declaredIn: 'A.swift', referencedByFiles: 2 },
      ],
    });
    expect(candidatesOnly).not.toContain('stored on spec.designSystem');
    expect(candidatesOnly).toContain('NOT stored');
    const withTokens = designScanKickoffBlock({
      designSystem: { spacing: [16] },
      componentCandidates: [],
    });
    expect(withTokens).toContain('stored on spec.designSystem');
  });
});

describe('findAssetColors / runDesignScan (filesystem)', () => {
  let dir: string;
  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it('walks xcassets catalogs and aggregates with swift sources', async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'tango-designscan-'));
    const colorset = path.join(dir, 'App/Assets.xcassets/Brand.colorset');
    await mkdir(colorset, { recursive: true });
    await writeFile(
      path.join(colorset, 'Contents.json'),
      JSON.stringify({
        colors: [
          { color: { components: { red: '0x61', green: '0x59', blue: '0xE1', alpha: '1' } } },
        ],
      }),
    );
    await mkdir(path.join(dir, 'App'), { recursive: true });
    await writeFile(
      path.join(dir, 'App/HomeView.swift'),
      'struct HomeView: View {\n  Color("Brand")\n  .padding(16)\n}',
    );

    const assets = await findAssetColors(dir);
    expect(assets).toEqual([{ name: 'Brand', value: '#6159E1' }]);

    const result = await runDesignScan(dir, [
      { relPath: 'App/HomeView.swift', generated: false },
      { relPath: 'TangoGenerated/TangoXScreen.swift', generated: true },
    ]);
    expect(result.designSystem.colors).toEqual([
      { name: 'Brand', value: '#6159E1', count: 1 },
    ]);
    expect(result.designSystem.spacing).toEqual([16]);
  });
});
