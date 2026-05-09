// Provider registry. The chat harness routes work to different models based
// on what kind of step is being run. Picking the right model is server-side —
// the orchestrator runs on `orchestrate`, sub-agent tools call `getModel` for
// their own task. The mapping lives here so it's the one place to retune.

import { openai as openaiProvider } from '@ai-sdk/openai';
import { anthropic } from '@ai-sdk/anthropic';
import { google } from '@ai-sdk/google';
import { generateText, type LanguageModel } from 'ai';

export type TaskType =
  | 'orchestrate' // long tool chains, the chat brain
  | 'vision' // screenshot/image analysis
  | 'code' // SwiftUI / TS synthesis
  | 'fast-ui' // cheap chatter, classifiers
  | 'summarize'; // memory.ts rewrite

export const MODEL_IDS = {
  orchestrate: 'claude-sonnet-4-6',
  code: 'claude-sonnet-4-6',
  'fast-ui': 'claude-haiku-4-5-20251001',
  vision: 'gemini-2.5-pro',
  summarize: 'gpt-5.5',
} as const;

export type ProviderName = 'anthropic' | 'google' | 'openai';

export function providerFor(task: TaskType): ProviderName {
  switch (task) {
    case 'orchestrate':
    case 'code':
    case 'fast-ui':
      return 'anthropic';
    case 'vision':
      return 'google';
    case 'summarize':
      return 'openai';
  }
}

export function getModel(task: TaskType): LanguageModel {
  switch (providerFor(task)) {
    case 'anthropic':
      return anthropic(MODEL_IDS[task]);
    case 'google':
      return google(MODEL_IDS[task]);
    case 'openai':
      return openaiProvider(MODEL_IDS[task]);
  }
}

// safeModel falls through provider chains when a key is missing. Provider
// constructors don't throw at construction time — they throw at call time —
// so we catch via env-var presence rather than try/catch. Logs once per
// missing-key combination.
const FALLBACK: Record<ProviderName, ProviderName[]> = {
  anthropic: ['anthropic', 'openai', 'google'],
  google: ['google', 'openai', 'anthropic'],
  openai: ['openai', 'anthropic', 'google'],
};

const ENV_KEY: Record<ProviderName, string> = {
  anthropic: 'ANTHROPIC_API_KEY',
  google: 'GOOGLE_GENERATIVE_AI_API_KEY',
  openai: 'OPENAI_API_KEY',
};

const warned = new Set<string>();

export function safeModel(task: TaskType): LanguageModel {
  const preferred = providerFor(task);
  const chain = FALLBACK[preferred];
  for (const p of chain) {
    if (process.env[ENV_KEY[p]]) {
      if (p !== preferred) {
        const k = `${preferred}->${p}`;
        if (!warned.has(k)) {
          warned.add(k);
          console.warn(
            `[ai] ${ENV_KEY[preferred]} missing — falling back to ${p} for task '${task}'`,
          );
        }
      }
      switch (p) {
        case 'anthropic':
          return anthropic(MODEL_IDS[task]);
        case 'google':
          return google(MODEL_IDS[task]);
        case 'openai':
          return openaiProvider(MODEL_IDS[task]);
      }
    }
  }
  // Nothing set — return the preferred model anyway; the SDK will surface a
  // helpful auth error at call time.
  return getModel(task);
}

// Back-compat re-exports. memory.ts and any not-yet-migrated callers still
// import `openai`, `generateText`, `VISION_MODEL`, `IMAGE_MODEL`. Keep them.
export { openaiProvider as openai, generateText };

export const VISION_MODEL = MODEL_IDS.summarize;
export const IMAGE_MODEL = 'gpt-image-2-2026-04-21' as const;
