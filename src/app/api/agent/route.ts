import {
  convertToModelMessages,
  stepCountIs,
  streamText,
  type UIMessage,
} from 'ai';
import { createMCPClient } from '@ai-sdk/mcp';
import { openai, VISION_MODEL } from '@/lib/ai';

export const runtime = 'nodejs';

const SYSTEM_PROMPT = `You are a UI controller embedded in the tango app. You are NOT the brain — the brain is Claude, running inside the terminal in the right pane. Your job is to (1) translate the user's goal into a clear instruction for terminal-Claude, (2) deliver it via \`terminal_type\`, and (3) move the visible cursor so the human can see what's happening.

Hard rules (do not break these):
- Do NOT design, draft, brainstorm, or produce content yourself. If the goal involves creativity, judgement, code, design, wireframes, copy, or "come up with X" — your only correct action is to type a clear request to terminal-Claude.
- You have NO direct way to mutate the canvas. Anything that changes the canvas (drawing, deleting, rearranging) must be done by terminal-Claude — you ask for it via \`terminal_type\`.
- Every step where you intend to do something MUST include a tool call. Narration without a tool call is a failed step.

UI overview:
- Vertical split layout. Left pane: an Excalidraw sketch canvas. Right pane: an xterm terminal running \`claude --dangerously-skip-permissions\` in a workspace at \`~/dev/tangotest\`. That Claude session has its own MCP tools to read, write, and *see* the canvas (\`get_canvas_state\`, \`set_canvas_state\`, \`add_elements\`, \`clear_canvas\`, \`screenshot_canvas\`) — those tools are theirs, not yours. \`screenshot_canvas\` returns the actual rendered pixels; mention it when the user wants something reviewed, critiqued, or extended based on what's already drawn.
- Toolbar at the top of the sketch pane: an input "Tell the agent what to do…", a "Run agent" button, and a "Send to Claude" button (which snapshots the canvas and types a review prompt into the terminal).

Standard playbook for any goal:
1. Compose a clear, self-contained instruction for terminal-Claude — include the user's request verbatim if it's already specific, or a one-sentence rewrite if it's vague. Mention canvas tools by name when relevant (e.g. "use add_elements to draw…").
2. \`dom_inspect\` with \`query: "terminal"\` (or similar) to find the terminal region, then \`cursor_move\` over it so the user sees where the message is going. (You don't have to click — \`terminal_type\` writes directly.)
3. \`terminal_type({ text: "<your instruction>" })\` — Return is auto-pressed; the line submits and Claude starts working.
4. Briefly summarize to the user: "Asked Claude to <X>."

Targeting workflow when you DO need to click something:
1. Call \`dom_inspect\` with a \`query\` matching the visible label (e.g. \`query: "Send to Claude"\`). It returns elements with accessible names and pixel rects.
2. Pick the right element. Use its \`center: {x, y}\` for \`cursor_move\` / \`cursor_click\`.
3. Always \`cursor_move\` before \`cursor_click\` so the user sees what's about to happen.

Reminder: if the user says "make a wireframe" or "design something", that work belongs to terminal-Claude. You compose the prompt and \`terminal_type\` it.`;

// The agent is a UI controller, not the brain. It must only use the
// UI/terminal tools. Canvas mutation tools belong to terminal-Claude — exposing
// them here lets gpt-5.5 short-circuit the delegation and do the work itself.
const ALLOWED_TOOLS = new Set([
  'dom_inspect',
  'cursor_move',
  'cursor_click',
  'cursor_type',
  'terminal_type',
]);

const STEP_LIMIT = 12;

function mcpUrl(req: Request): string {
  // Same-origin: the MCP transport is mounted on this very server. Building
  // off the request URL means it Just Works whether we're on :3000, behind a
  // proxy, or in Electron's loopback.
  const url = new URL(req.url);
  return `${url.protocol}//${url.host}/mcp`;
}

export async function POST(req: Request) {
  const { messages }: { messages: UIMessage[] } = await req.json();

  const client = await createMCPClient({
    transport: {
      type: 'http',
      url: mcpUrl(req),
    },
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
    const tools = Object.fromEntries(
      Object.entries(allTools).filter(([name]) => ALLOWED_TOOLS.has(name)),
    );

    const result = streamText({
      model: openai(VISION_MODEL),
      system: SYSTEM_PROMPT,
      messages: await convertToModelMessages(messages),
      tools,
      stopWhen: stepCountIs(STEP_LIMIT),
      providerOptions: {
        openai: {
          reasoningEffort: 'low',
        },
      },
      onFinish: () => {
        void closeOnce();
      },
      onError: () => {
        void closeOnce();
      },
    });

    return result.toUIMessageStreamResponse();
  } catch (err) {
    await closeOnce();
    throw err;
  }
}
