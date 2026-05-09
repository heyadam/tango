import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { MODEL_IDS, getModel, providerFor, safeModel } from './ai';

describe('providerFor', () => {
  it('routes orchestrate/code/fast-ui to anthropic', () => {
    expect(providerFor('orchestrate')).toBe('anthropic');
    expect(providerFor('code')).toBe('anthropic');
    expect(providerFor('fast-ui')).toBe('anthropic');
  });

  it('routes vision to google', () => {
    expect(providerFor('vision')).toBe('google');
  });

  it('routes summarize to openai', () => {
    expect(providerFor('summarize')).toBe('openai');
  });
});

describe('getModel', () => {
  it('returns a model object with a modelId matching the registry', () => {
    for (const task of [
      'orchestrate',
      'code',
      'fast-ui',
      'vision',
      'summarize',
    ] as const) {
      const m = getModel(task);
      // The AI SDK's LanguageModel exposes the model id as `.modelId`.
      expect((m as unknown as { modelId: string }).modelId).toBe(
        MODEL_IDS[task],
      );
    }
  });
});

describe('safeModel fallback chain', () => {
  const ORIG_ENV = { ...process.env };

  beforeEach(() => {
    delete process.env.ANTHROPIC_API_KEY;
    delete process.env.GOOGLE_GENERATIVE_AI_API_KEY;
    delete process.env.OPENAI_API_KEY;
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
  });

  it('uses the preferred provider when its key is set', () => {
    process.env.ANTHROPIC_API_KEY = 'x';
    const m = safeModel('orchestrate');
    expect((m as unknown as { provider: string }).provider).toMatch(/anthropic/);
  });

  it('falls back to openai when preferred (anthropic) key is missing', () => {
    process.env.OPENAI_API_KEY = 'x';
    const m = safeModel('code');
    expect((m as unknown as { provider: string }).provider).toMatch(/openai/);
  });

  it('falls back to anthropic for vision when google key missing', () => {
    process.env.ANTHROPIC_API_KEY = 'x';
    const m = safeModel('vision');
    // Falls through google → openai → anthropic per FALLBACK chain.
    expect((m as unknown as { provider: string }).provider).toMatch(/anthropic/);
  });

  it('returns preferred provider model when no keys are set (deferred to call-time auth error)', () => {
    const m = safeModel('summarize');
    expect((m as unknown as { provider: string }).provider).toMatch(/openai/);
  });
});
