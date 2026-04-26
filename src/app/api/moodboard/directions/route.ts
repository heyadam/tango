import * as z from 'zod/v4';
import { IMAGE_MODEL, VISION_MODEL } from '@/lib/ai';
import { appendEvent } from '@/server/memory';
import { saveMoodboardPng } from '@/server/moodboard';
import { getWorkspaceOrNull } from '@/server/workspace';

export const runtime = 'nodejs';

const sizes = ['1024x1024', '1536x1024', '1024x1536'] as const;
const qualities = ['low', 'medium', 'high', 'auto'] as const;
const modes = ['complete', 'logo', 'ui-elements', 'random'] as const;

type MoodboardSize = (typeof sizes)[number];
type MoodboardQuality = (typeof qualities)[number];
type MoodboardMode = (typeof modes)[number];

type Body = {
  brief: string;
  size?: MoodboardSize;
  quality?: MoodboardQuality;
  mode?: MoodboardMode;
};

// Loose shape for logo / ui-elements / random — only title + imagePrompt are
// guaranteed; the rest are optional because the per-mode prompt doesn't ask
// for them.
const directionSchema = z.object({
  title: z.string().min(2),
  rationale: z.string().optional(),
  palette: z.array(z.string().min(3)).max(7).optional(),
  brandNotes: z.string().optional(),
  uiNotes: z.string().optional(),
  imagePrompt: z.string().min(40),
});

// Strict shape for `complete` mode — the full-moodboard contract. If the
// model skips a palette or returns a one-line rationale, fail loudly here
// rather than silently shipping a broken moodboard to the UI.
const completeDirectionSchema = directionSchema.extend({
  rationale: z.string().min(20),
  palette: z.array(z.string().min(3)).min(4).max(7),
  brandNotes: z.string().min(20),
  uiNotes: z.string().min(20),
  imagePrompt: z.string().min(80),
});

const directionsSchema = z.object({
  directions: z.array(directionSchema),
});

const completeDirectionsSchema = z.object({
  directions: z.array(completeDirectionSchema),
});

const bodySchema = z.object({
  brief: z.string().trim().min(3).max(4000),
  size: z.enum(sizes).optional(),
  quality: z.enum(qualities).optional(),
  mode: z.enum(modes).optional(),
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

function systemPrompt(mode: MoodboardMode): string {
  switch (mode) {
    case 'logo':
      return `You design one app logo concept. Return a single-image generation prompt for a polished logo composition. Avoid generic style labels unless you make them specific. Do not mention that you are an AI.`;
    case 'ui-elements':
      return `You design one UI elements exploration. Return a single-image generation prompt that shows realistic UI fragments — buttons, inputs, cards, navigation, list rows — laid out cleanly in a coherent style. Do not mention that you are an AI.`;
    case 'random':
      return `You produce one piece of random design inspiration loosely related to the brief. Return a single evocative image generation prompt. The result should spark ideas, not commit to a brand system. Do not mention that you are an AI.`;
    case 'complete':
    default:
      return `You create one creative direction spec for a product branding and UI moodboard.

The direction must be practical for a designer or engineer to turn into a brand/UI exploration. Avoid generic style labels unless you make them specific. Do not mention that you are an AI.`;
  }
}

function userPrompt(brief: string, mode: MoodboardMode): string {
  switch (mode) {
    case 'logo':
      return `Creative brief:
${brief}

Design one app logo concept. The imagePrompt should describe a single polished image: the logo as a hero composition, possibly with a wordmark and a small set of mark variants (mono / inverse) on a clean background. No moodboard collage, no UI fragments.

Return only valid JSON in this exact shape (omit fields you don't need):
{
  "directions": [
    {
      "title": "short concept name",
      "imagePrompt": "detailed prompt for one polished logo image"
    }
  ]
}`;
    case 'ui-elements':
      return `Creative brief:
${brief}

Design one UI elements exploration. The imagePrompt should describe a single polished image showing realistic UI fragments — buttons, form fields, cards, nav, list rows — laid out cleanly with consistent spacing and typography.

Return only valid JSON in this exact shape (omit fields you don't need):
{
  "directions": [
    {
      "title": "short concept name",
      "uiNotes": "what these UI fragments imply about the system",
      "imagePrompt": "detailed prompt for one polished UI elements image"
    }
  ]
}`;
    case 'random':
      return `Creative brief:
${brief}

Surprise the user with one piece of random design inspiration loosely related to the brief. The imagePrompt should describe a single evocative image — photography, illustration, texture, scene, or abstract — anything that sparks ideas.

Return only valid JSON in this exact shape (omit fields you don't need):
{
  "directions": [
    {
      "title": "short evocative name",
      "imagePrompt": "detailed prompt for one evocative inspiration image"
    }
  ]
}`;
    case 'complete':
    default:
      return `Creative brief:
${brief}

Create one moodboard direction. The imagePrompt should describe a single polished landscape moodboard image that includes brand identity, product UI fragments, typography samples, color/material swatches, and interaction/style cues. The image should contain useful design artifacts, not just atmosphere.

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

async function planDirections(brief: string, mode: MoodboardMode) {
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
          content: [{ type: 'input_text', text: systemPrompt(mode) }],
        },
        {
          role: 'user',
          content: [{ type: 'input_text', text: userPrompt(brief, mode) }],
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
  const schema =
    mode === 'complete' ? completeDirectionsSchema : directionsSchema;
  return schema.parse(parseJsonObject(text));
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

  const mode = body.mode ?? 'complete';
  const size = body.size ?? '1536x1024';
  const quality = body.quality ?? 'medium';

  try {
    const planned = await planDirections(body.brief, mode);
    const spec = planned.directions[0];
    if (!spec) {
      throw new Error('Planner returned no directions.');
    }

    const image = await generateMoodboardImage(
      spec.imagePrompt,
      size,
      quality,
    );

    const workspace = getWorkspaceOrNull();
    let relPath: string | undefined;
    if (workspace) {
      try {
        relPath = await saveMoodboardPng(workspace, image.base64);
        // Fire-and-forget: appendEvent enqueues internally and never throws.
        appendEvent({
          type: 'snapshot',
          relPath,
          caption: `moodboard · ${spec.title}`,
        });
      } catch (err) {
        // Disk write failed — surface to logs but don't fail the whole
        // generation. The UI still has the base64 to render and the user
        // can retry/regenerate.
        console.error(
          '[moodboard] failed to persist generated image:',
          err instanceof Error ? err.message : String(err),
        );
      }
    }

    const direction = {
      id: crypto.randomUUID(),
      title: spec.title,
      rationale: spec.rationale,
      palette: spec.palette,
      brandNotes: spec.brandNotes,
      uiNotes: spec.uiNotes,
      imagePrompt: spec.imagePrompt,
      base64: image.base64,
      mediaType: image.mediaType,
      relPath,
    };

    // Always one direction; kept as an array so the response shape matches
    // the seed endpoint and lets the client treat both uniformly.
    return Response.json({ directions: [direction] });
  } catch (err) {
    const message =
      err instanceof Error ? err.message : 'Failed to generate directions.';
    return Response.json({ error: message }, { status: 500 });
  }
}
