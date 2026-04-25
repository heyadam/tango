import * as z from 'zod/v4';
import { IMAGE_MODEL, VISION_MODEL } from '@/lib/ai';

export const runtime = 'nodejs';

const sizes = ['1024x1024', '1536x1024', '1024x1536'] as const;
const qualities = ['low', 'medium', 'high', 'auto'] as const;

type MoodboardSize = (typeof sizes)[number];
type MoodboardQuality = (typeof qualities)[number];

type Body = {
  brief: string;
  count?: number;
  size?: MoodboardSize;
  quality?: MoodboardQuality;
};

const directionSchema = z.object({
  title: z.string().min(2),
  rationale: z.string().min(20),
  palette: z.array(z.string().min(3)).min(4).max(7),
  brandNotes: z.string().min(20),
  uiNotes: z.string().min(20),
  imagePrompt: z.string().min(80),
});

const directionsSchema = z.object({
  directions: z.array(directionSchema),
});

const bodySchema = z.object({
  brief: z.string().trim().min(3).max(4000),
  count: z.number().int().min(1).max(6).optional(),
  size: z.enum(sizes).optional(),
  quality: z.enum(qualities).optional(),
});

function parseBody(raw: unknown): Body {
  const parsed = bodySchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(parsed.error.issues[0]?.message ?? 'Invalid request body');
  }
  return parsed.data;
}

async function readBody(req: Request): Promise<Body> {
  const raw = await req.text();
  if (!raw.trim()) {
    throw new Error('Request body is required.');
  }
  try {
    return parseBody(JSON.parse(raw));
  } catch (err) {
    if (err instanceof SyntaxError) {
      throw new Error('Request body must be valid JSON.');
    }
    throw err;
  }
}

function systemPrompt(count: number): string {
  return `You create divergent creative direction specs for product branding and UI moodboards.

Return exactly ${count} directions. Make them meaningfully different from one another in audience, visual language, brand personality, typography attitude, palette, and interface treatment.

Each direction must be practical for a designer or engineer to turn into a brand/UI exploration. Avoid generic style labels unless you make them specific. Do not mention that you are an AI.`;
}

function userPrompt(brief: string, count: number): string {
  return `Creative brief:
${brief}

Create ${count} distinct moodboard directions. For each imagePrompt, describe a single polished landscape moodboard image that includes brand identity, product UI fragments, typography samples, color/material swatches, and interaction/style cues. The image should contain useful design artifacts, not just atmosphere.

Return only valid JSON in this exact shape:
{
  "directions": [
    {
      "title": "short direction name",
      "rationale": "why this direction fits",
      "palette": ["#112233 - color role", "#445566 - color role", "#778899 - color role", "#aabbcc - color role"],
      "brandNotes": "brand identity notes",
      "uiNotes": "product UI notes",
      "imagePrompt": "detailed prompt for one polished moodboard image"
    }
  ]
}`;
}

function parseJsonObject(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) throw new Error('The direction planner did not return JSON.');
    return JSON.parse(match[0]);
  }
}

function outputText(response: unknown): string {
  if (!response || typeof response !== 'object') return '';
  const top = response as { output_text?: unknown; output?: unknown };
  if (typeof top.output_text === 'string') return top.output_text;
  if (!Array.isArray(top.output)) return '';

  const parts: string[] = [];
  for (const item of top.output) {
    if (!item || typeof item !== 'object') continue;
    const content = (item as { content?: unknown }).content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (!part || typeof part !== 'object') continue;
      const maybeText = (part as { text?: unknown }).text;
      if (typeof maybeText === 'string') parts.push(maybeText);
    }
  }
  return parts.join('\n').trim();
}

async function planDirections(brief: string, count: number) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error('OPENAI_API_KEY is not configured.');
  }

  const res = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: VISION_MODEL,
      input: [
        {
          role: 'system',
          content: [{ type: 'input_text', text: systemPrompt(count) }],
        },
        {
          role: 'user',
          content: [{ type: 'input_text', text: userPrompt(brief, count) }],
        },
      ],
      reasoning: { effort: 'low' },
    }),
  });

  const raw = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new Error(raw || `OpenAI planning failed: ${res.status}`);
  }
  if (!res.ok) {
    const error = body as { error?: { message?: string } };
    throw new Error(error.error?.message ?? `OpenAI planning failed: ${res.status}`);
  }

  const text = outputText(body);
  if (!text) {
    throw new Error('OpenAI planning response did not include text.');
  }
  return directionsSchema.parse(parseJsonObject(text));
}

async function generateMoodboardImage(
  prompt: string,
  size: MoodboardSize,
  quality: MoodboardQuality,
) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error('OPENAI_API_KEY is not configured.');
  }

  const res = await fetch('https://api.openai.com/v1/images/generations', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: IMAGE_MODEL,
      prompt,
      size,
      quality,
    }),
  });

  const raw = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new Error(raw || `OpenAI image generation failed: ${res.status}`);
  }
  if (!res.ok) {
    const error = body as { error?: { message?: string } };
    throw new Error(
      error.error?.message ?? `OpenAI image generation failed: ${res.status}`,
    );
  }

  const image = (body as { data?: Array<{ b64_json?: unknown }> }).data?.[0]
    ?.b64_json;
  if (typeof image !== 'string') {
    throw new Error('OpenAI image response did not include image data.');
  }
  return { base64: image, mediaType: 'image/png' };
}

export async function POST(req: Request) {
  let body: Body;
  try {
    body = await readBody(req);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Invalid request body';
    return Response.json({ error: message }, { status: 400 });
  }

  const count = body.count ?? 3;
  const size = body.size ?? '1536x1024';
  const quality = body.quality ?? 'medium';

  try {
    const planned = await planDirections(body.brief, count);
    const specs = planned.directions.slice(0, count);

    if (specs.length !== count) {
      throw new Error(`Expected ${count} directions, received ${specs.length}.`);
    }

    const directions = [];
    for (let index = 0; index < specs.length; index += 1) {
      const spec = specs[index];
      const image = await generateMoodboardImage(
        spec.imagePrompt,
        size,
        quality,
      );

      directions.push({
        id: crypto.randomUUID(),
        title: spec.title,
        rationale: spec.rationale,
        palette: spec.palette,
        brandNotes: spec.brandNotes,
        uiNotes: spec.uiNotes,
        imagePrompt: spec.imagePrompt,
        base64: image.base64,
        mediaType: image.mediaType,
      });
    }

    return Response.json({ directions });
  } catch (err) {
    const message =
      err instanceof Error ? err.message : 'Failed to generate directions.';
    return Response.json({ error: message }, { status: 500 });
  }
}
