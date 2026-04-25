import { convertToModelMessages, streamText, type UIMessage } from 'ai';
import { openai, VISION_MODEL } from '@/lib/ai';

export const runtime = 'nodejs';

export async function POST(req: Request) {
  const { messages }: { messages: UIMessage[] } = await req.json();

  const result = streamText({
    model: openai(VISION_MODEL),
    messages: await convertToModelMessages(messages),
  });

  return result.toUIMessageStreamResponse({
    onError: (error) =>
      error instanceof Error ? error.message : String(error),
  });
}
