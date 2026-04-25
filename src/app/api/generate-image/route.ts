import { IMAGE_MODEL } from '@/lib/ai';

export const runtime = 'nodejs';

const sizes = ['1024x1024', '1536x1024', '1024x1536', 'auto'] as const;
const qualities = ['low', 'medium', 'high', 'auto'] as const;

type ImageSize = (typeof sizes)[number];
type ImageQuality = (typeof qualities)[number];

type Body = {
  prompt: string;
  size?: ImageSize;
  quality?: ImageQuality;
};

function parseBody(raw: unknown): Body {
  if (!raw || typeof raw !== 'object') {
    throw new Error('Request body is required.');
  }
  const body = raw as Partial<Body>;
  if (!body.prompt || typeof body.prompt !== 'string') {
    throw new Error('prompt is required');
  }
  if (body.size && !sizes.includes(body.size)) {
    throw new Error('Unsupported image size.');
  }
  if (body.quality && !qualities.includes(body.quality)) {
    throw new Error('Unsupported image quality.');
  }
  return body as Body;
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

async function generateImage(prompt: string, size: ImageSize, quality: ImageQuality) {
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

  const base64 = (body as { data?: Array<{ b64_json?: unknown }> }).data?.[0]
    ?.b64_json;
  if (typeof base64 !== 'string') {
    throw new Error('OpenAI image response did not include image data.');
  }
  return { base64, mediaType: 'image/png' };
}

export async function POST(req: Request) {
  let body: Body;
  try {
    body = await readBody(req);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Invalid request body';
    return Response.json({ error: message }, { status: 400 });
  }

  try {
    const image = await generateImage(
      body.prompt,
      body.size ?? 'auto',
      body.quality ?? 'auto',
    );

    return Response.json(image);
  } catch (err) {
    const message =
      err instanceof Error ? err.message : 'Failed to generate image.';
    return Response.json({ error: message }, { status: 500 });
  }
}
