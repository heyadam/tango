import {
  convertToModelMessages,
  generateText,
  stepCountIs,
  streamText,
  tool,
  type ToolCallOptions,
  type UIMessage,
} from 'ai';
import { createMCPClient } from '@ai-sdk/mcp';
import { z } from 'zod';
import { safeModel } from '@/lib/ai';
import { appendEvent } from '@/server/memory';
import {
  errorTextFromResult,
  extractScreenshotImage,
  isErrorResult,
} from './extractScreenshot';
import { filterAllowedTools, lastUserGoal, mcpUrl } from './helpers';

export const runtime = 'nodejs';

// Tango's chat harness IS the brain. Sub-agent tools (vision, swiftui) call
// out to model providers tuned for those tasks; the orchestrator stays in
// charge of when and why to invoke them.
const SYSTEM_PROMPT = `You are tango — the AI brain of an iOS-design IDE. The user works in two surfaces visible to you:

- A canvas (Excalidraw) on the left for sketching layouts, diagrams, and screen flows.
- A UI mock spec (shadcn/Tailwind components, screen graph) the canvas can hand off to.

Your tools let you:
- Read and mutate the canvas: \`get_canvas_state\`, \`set_canvas_state\`, \`add_elements\`, \`clear_canvas\`, \`screenshot_canvas\`, \`set_screen_flow\`.
- Read and mutate the UI mock spec: \`get_ui_mock\`, \`get_ui_viewport\`, \`set_ui_mock\`, \`add_ui_screen\`, \`clear_ui_mock\`.
- Build and run the iOS app: \`ios_status\`, \`ios_build_run\`, \`ios_logs_recent\`.
- Persist decisions and todos: \`remember_note\`.
- Delegate to specialist models:
  - \`vision_describe_canvas\` — vision-tuned model reads the current canvas screenshot and returns a structured description. Use before designing on top of an existing sketch.
  - \`synthesize_swiftui\` — code-tuned model writes SwiftUI source from a spec.

Working rules:
- Prefer one large \`set_canvas_state\` / \`set_ui_mock\` over many small mutations.
- For "what does my canvas show right now?", call \`vision_describe_canvas\` rather than asking the user.
- After non-trivial decisions, call \`remember_note\` so future sessions inherit the context.
- Be concise in chat replies; the user is watching tool calls land in real time.`;

const STEP_LIMIT = 20;

export async function POST(req: Request) {
  const { messages }: { messages: UIMessage[] } = await req.json();

  const client = await createMCPClient({
    transport: { type: 'http', url: mcpUrl(req) },
  });

  let closed = false;
  const closeOnce = async () => {
    if (closed) return;
    closed = true;
    try {
      await client.close();
    } catch {
      /* noop */
    }
  };

  try {
    const allTools = await client.tools();
    const mcpTools = filterAllowedTools(allTools);

    type McpExecutableTool = {
      execute: (
        input: Record<string, unknown>,
        options: ToolCallOptions,
      ) => Promise<unknown>;
    };

    const localTools = {
      vision_describe_canvas: tool({
        description:
          "Take a fresh screenshot of the canvas and describe it via a vision-tuned model (Gemini). Use when you need to know what the user has drawn and the JSON from get_canvas_state isn't enough (e.g. embedded raster images, hand-drawn shapes).",
        inputSchema: z.object({
          focus: z
            .string()
            .optional()
            .describe(
              'Optional aspect to emphasize, e.g. "layout", "color palette", "interactive elements".',
            ),
        }),
        execute: async ({ focus }, options) => {
          const screenshotTool = (mcpTools as Record<string, unknown>)
            .screenshot_canvas as McpExecutableTool | undefined;
          if (!screenshotTool) {
            return { error: 'screenshot_canvas tool not available' };
          }
          const shot = await screenshotTool.execute({}, options);
          if (isErrorResult(shot)) {
            return { error: errorTextFromResult(shot) };
          }
          const image = extractScreenshotImage(shot);
          if (!image) {
            return { error: 'screenshot returned no image data' };
          }
          const { text } = await generateText({
            model: safeModel('vision'),
            abortSignal: options.abortSignal,
            messages: [
              {
                role: 'user',
                content: [
                  {
                    type: 'text',
                    text: `Describe this design${focus ? `, focusing on: ${focus}` : ''}. Be concrete: list components, spatial layout, and notable visual choices.`,
                  },
                  {
                    type: 'image',
                    image: image.data,
                    mediaType: image.mimeType,
                  },
                ],
              },
            ],
          });
          return { description: text };
        },
      }),

      synthesize_swiftui: tool({
        description:
          'Generate SwiftUI source from a design spec via a code-tuned model (Sonnet). Returns the code as a string for the orchestrator to share with the user or hand to a build tool.',
        inputSchema: z.object({
          spec: z
            .string()
            .describe(
              'Concrete description of the screen to build: components, layout, state, navigation.',
            ),
          screen: z
            .string()
            .optional()
            .describe('Optional screen name (e.g. "ProfileView").'),
        }),
        execute: async ({ spec, screen }, options) => {
          const { text } = await generateText({
            model: safeModel('code'),
            abortSignal: options.abortSignal,
            prompt: `Write idiomatic SwiftUI for the screen "${screen ?? 'main'}". Return ONLY the Swift source — no markdown fence, no commentary.

Spec:
${spec}`,
          });
          return { swift: text };
        },
      }),
    };

    const goal = lastUserGoal(messages);

    const result = streamText({
      model: safeModel('orchestrate'),
      system: SYSTEM_PROMPT,
      messages: await convertToModelMessages(messages),
      tools: { ...mcpTools, ...localTools },
      stopWhen: stepCountIs(STEP_LIMIT),
      onFinish: (event) => {
        try {
          const toolNames: string[] = [];
          for (const step of event.steps ?? []) {
            for (const call of step.toolCalls ?? []) {
              if (call?.toolName) toolNames.push(call.toolName);
            }
          }
          const toolsLine = toolNames.join('→');
          const finalText = (event.text ?? '').trim();
          const outcome = `${finalText.slice(0, 80)}${
            finalText.length > 80 ? '…' : ''
          } [${event.finishReason}]`;
          if (goal) {
            appendEvent({
              type: 'agent_run',
              goal,
              tools: toolsLine,
              outcome,
            });
          }
        } catch (err) {
          console.error('[chat] memory append failed:', err);
        }
        void closeOnce();
      },
      onError: () => {
        void closeOnce();
      },
    });

    return result.toUIMessageStreamResponse({
      onError: (e) => (e instanceof Error ? e.message : String(e)),
    });
  } catch (err) {
    await closeOnce();
    throw err;
  }
}
