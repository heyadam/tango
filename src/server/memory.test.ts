import { describe, it, expect } from 'vitest';
import {
  parseFile,
  sliceBetween,
  foldIntoSummary,
  formatEntry,
  countRecentEntries,
  rescueMalformed,
  serialize,
} from './memory';

const SUMMARY_END = '<!-- tango:summary:end -->';
const RECENT_START = '<!-- tango:recent:start -->';
const RECENT_END = '<!-- tango:recent:end -->';
const USER_START = '<!-- tango:user:start -->';
const USER_END = '<!-- tango:user:end -->';

const ISO = '2026-04-26T00:00:00.000Z';

function wellFormed(opts?: {
  header?: string;
  summary?: string;
  recent?: string;
  user?: string;
}): string {
  const header = opts?.header ?? '# tango workspace memory\n\n';
  const summary = opts?.summary ?? '\n## Summary\n\n_No prior history yet._\n';
  const recent = opts?.recent ?? '\n## Recent\n\n';
  const user = opts?.user ?? '\n## Notes\n\n';
  return (
    header +
    `<!-- tango:summary:start v=1 updated=${ISO} -->` +
    summary +
    SUMMARY_END +
    '\n\n' +
    RECENT_START +
    recent +
    RECENT_END +
    '\n\n' +
    USER_START +
    user +
    USER_END +
    '\n'
  );
}

describe('sliceBetween', () => {
  it('extracts content between string markers', () => {
    const r = sliceBetween('AAA<start>body<end>ZZZ', '<start>', '<end>');
    expect(r).toEqual({ before: 'AAA', body: 'body', after: 'ZZZ' });
  });

  it('extracts content with regex start matcher', () => {
    const r = sliceBetween('AAA<start v=1>body<end>ZZZ', /<start[^>]*>/, '<end>');
    expect(r).toEqual({ before: 'AAA', body: 'body', after: 'ZZZ' });
  });

  it('returns null when start marker missing', () => {
    expect(sliceBetween('no markers here', '<start>', '<end>')).toBeNull();
  });

  it('returns null when end marker missing after start', () => {
    expect(sliceBetween('A<start>body without close', '<start>', '<end>')).toBeNull();
  });

  it('uses the leftmost regex match', () => {
    const r = sliceBetween('A<x>1<y>B<x>2<y>C', /<x>/, '<y>');
    expect(r).toEqual({ before: 'A', body: '1', after: 'B<x>2<y>C' });
  });
});

describe('parseFile', () => {
  it('parses a well-formed file', () => {
    const raw = wellFormed();
    const p = parseFile(raw);
    expect(p).not.toBeNull();
    expect(p!.header).toBe('# tango workspace memory\n\n');
    expect(p!.summary).toContain('No prior history yet');
    expect(p!.recent).toContain('## Recent');
    expect(p!.user).toContain('## Notes');
    expect(p!.trailer).toBe('\n');
  });

  it('returns null when summary fence is missing', () => {
    const raw = `header\n${RECENT_START}\nbody\n${RECENT_END}\n${USER_START}\n${USER_END}\n`;
    expect(parseFile(raw)).toBeNull();
  });

  it('returns null when recent fence is missing', () => {
    const raw = wellFormed().replace(RECENT_START, '<!-- not-recent -->');
    expect(parseFile(raw)).toBeNull();
  });

  it('returns null when user fence is missing', () => {
    const raw = wellFormed().replace(USER_START, '<!-- not-user -->');
    expect(parseFile(raw)).toBeNull();
  });

  it('returns null on a fully malformed file', () => {
    expect(parseFile('completely freeform content')).toBeNull();
  });
});

describe('serialize', () => {
  it('round-trips: serialize(parseFile(x)) === x for well-formed input', () => {
    const raw = wellFormed();
    const p = parseFile(raw);
    expect(p).not.toBeNull();
    expect(serialize(p!, ISO)).toBe(raw);
  });

  it('round-trips with custom content', () => {
    const raw = wellFormed({
      summary: '\nA distilled story.\n',
      recent: '\n- 2026-04-26 [note/decision] Chose vitest\n',
      user: '\nMy own notes.\n',
    });
    const p = parseFile(raw);
    expect(p).not.toBeNull();
    expect(serialize(p!, ISO)).toBe(raw);
  });
});

describe('formatEntry', () => {
  const ts = '2026-04-26 12:00';

  it('formats a note with category', () => {
    const out = formatEntry(
      { type: 'note', category: 'decision', text: 'Use vitest' },
      ts,
    );
    expect(out).toBe(`- ${ts} [note/decision] Use vitest`);
  });

  it('collapses whitespace in note text (oneLine)', () => {
    const out = formatEntry(
      { type: 'note', category: 'context', text: 'a\n  b\t c' },
      ts,
    );
    expect(out).toBe(`- ${ts} [note/context] a b c`);
  });
});

describe('foldIntoSummary', () => {
  const emptySummary = '\n## Summary\n\n_No prior history yet._\n';

  it('moves folded entries verbatim into the summary body', () => {
    const folded = [
      '- 2026-04-26 [note/decision] one',
      '- 2026-04-26 [note/context] two',
    ];
    const out = foldIntoSummary(emptySummary, folded);
    expect(out).toBe(`\n## Summary\n\n${folded.join('\n')}\n`);
  });

  it('drops the empty-state placeholder', () => {
    const out = foldIntoSummary(emptySummary, ['- entry']);
    expect(out).not.toContain('No prior history yet');
  });

  it('preserves legacy free-text summaries above the archived lines', () => {
    const legacy = '\n## Summary\n\nThe app is a todo list.\n';
    const out = foldIntoSummary(legacy, ['- entry one']);
    const body = out.replace('\n## Summary\n\n', '');
    expect(body.indexOf('The app is a todo list.')).toBeLessThan(
      body.indexOf('- entry one'),
    );
  });

  it('appends to an existing archive across successive folds', () => {
    const first = foldIntoSummary(emptySummary, ['- old-1']);
    const second = foldIntoSummary(first, ['- old-2']);
    const body = second.replace('\n## Summary\n\n', '').trimEnd();
    expect(body.split('\n')).toEqual(['- old-1', '- old-2']);
  });

  it('drops the oldest lines once the byte cap is exceeded', () => {
    const line = (i: number) => `- ${String(i).padStart(4, '0')} ${'x'.repeat(120)}`;
    const folded = Array.from({ length: 200 }, (_, i) => line(i));
    const out = foldIntoSummary(emptySummary, folded);
    expect(Buffer.byteLength(out, 'utf8')).toBeLessThan(17 * 1024);
    expect(out).not.toContain(line(0)); // oldest dropped
    expect(out).toContain(line(199)); // newest kept
  });
});

describe('countRecentEntries', () => {
  it('counts entry-prefixed lines only', () => {
    const block = `## Recent

- 2026-04-26 [note/context] one
- 2026-04-26 [note/context] two
not an entry
- 2026-04-26 [snapshot] three
`;
    expect(countRecentEntries(block)).toBe(3);
  });

  it('returns 0 for an empty block', () => {
    expect(countRecentEntries('')).toBe(0);
    expect(countRecentEntries('## Recent\n\n')).toBe(0);
  });

  it('ignores indented dashes', () => {
    expect(countRecentEntries('  - indented\n- top-level\n')).toBe(2);
  });
});

describe('rescueMalformed', () => {
  it('wraps existing content verbatim inside the user-notes block', () => {
    const orig = '# my old notes\n\nstuff I wrote';
    const out = rescueMalformed(orig);
    // Skeleton is well-formed — parseFile must succeed.
    const p = parseFile(out);
    expect(p).not.toBeNull();
    // The user block contains the rescued content.
    expect(p!.user).toContain(orig);
    expect(p!.user).toContain('found in this file before tango took it over');
  });

  it('produces a parseable skeleton even with empty input', () => {
    const out = rescueMalformed('');
    expect(parseFile(out)).not.toBeNull();
  });
});
