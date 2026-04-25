import { generateImage } from 'ai';
import { openai, IMAGE_MODEL } from '@/lib/ai';

export const runtime = 'nodejs';

type Body = {
  prompt: string;
  size?: `${number}x${number}`;
  quality?: 'low' | 'medium' | 'high' | 'auto';
};

export async function POST(req: Request) {
  const { prompt, size, quality }: Body = await req.json();

  if (!prompt || typeof prompt !== 'string') {
    return Response.json({ error: 'prompt is required' }, { status: 400 });
  }

  const { image } = await generateImage({
    model: openai.image(IMAGE_MODEL),
    prompt,
    ...(size ? { size } : {}),
    providerOptions: { openai: { quality: quality ?? 'auto' } },
  });

  return Response.json({
    base64: image.base64,
    mediaType: image.mediaType ?? 'image/png',
  });
}
