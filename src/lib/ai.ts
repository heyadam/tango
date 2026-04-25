import { openai } from '@ai-sdk/openai';
import { generateText } from 'ai';

export { openai, generateText };

export const VISION_MODEL = 'gpt-5.5' as const;

export const IMAGE_MODEL = 'gpt-image-2-2026-04-21' as const;
