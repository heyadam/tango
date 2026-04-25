// In-process MCP server. Mounted on the bare http.createServer in server.ts —
// NOT under app/api/.../route.ts, because the Streamable HTTP transport wants
// Node IncomingMessage/ServerResponse, not Web Fetch Request/Response.
//
// Tools live alongside canvasBridge in the same Node process so they can read
// and write the scene cache without IPC. The browser is told about scene
// changes via the /ws/canvas bridge.

import { randomUUID } from 'node:crypto';
import type http from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import * as z from 'zod/v4';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import {
  appendElementsFromServer,
  clearCanvasFromServer,
  getCanvasState,
  requestScreenshot,
  setCanvasFromServer,
  type CanvasElement,
} from './canvasBridge';
import { pushCursorCommand, requestInspect } from './agentCursorBridge';
import { recordNote } from './memory';

const elementSchema = z.array(z.record(z.string(), z.unknown()));
// Permissive Zod shape — we don't reproduce Excalidraw's element schema here.
// Excalidraw will reject malformed elements at updateScene() time on the
// client; we surface that as the tool result.

function buildServer(): McpServer {
  const server = new McpServer({
    name: 'tango-canvas',
    version: '0.1.0',
  });

  server.registerTool(
    'get_canvas_state',
    {
      title: 'Read the canvas',
      description:
        'Returns the current Excalidraw scene. `elements` is the array shape produced by the `elements` field of `serializeAsJSON`. `fileKeys` lists the IDs of any embedded image files in the scene; the binary file bytes themselves are not inlined to keep the response small.',
    },
    async () => {
      const { elements, appState, files } = getCanvasState();
      const payload = {
        elements,
        appState,
        fileKeys: Object.keys(files),
      };
      return {
        content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
      };
    },
  );

  server.registerTool(
    'set_canvas_state',
    {
      title: 'Replace the canvas',
      description:
        'Replaces the entire canvas with the provided elements. `elements` must match the shape of the `elements` field returned by `get_canvas_state`. Call `get_canvas_state` first if you need to see the current scene shape. Useful for proposing wireframes or full-screen redesigns.',
      inputSchema: {
        elements: elementSchema,
        appState: z.record(z.string(), z.unknown()).optional(),
      },
    },
    async ({ elements, appState }) => {
      setCanvasFromServer(elements as CanvasElement[], appState);
      return {
        content: [
          {
            type: 'text',
            text: `Replaced canvas with ${elements.length} element(s).`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'add_elements',
    {
      title: 'Append to the canvas',
      description:
        'Appends new elements to the existing canvas without disturbing what is already there. `elements` must match the shape of the `elements` field returned by `get_canvas_state`. Useful for adding annotations, callouts, or new shapes alongside existing work.',
      inputSchema: {
        elements: elementSchema,
      },
    },
    async ({ elements }) => {
      appendElementsFromServer(elements as CanvasElement[]);
      return {
        content: [
          {
            type: 'text',
            text: `Appended ${elements.length} element(s) to the canvas.`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'clear_canvas',
    {
      title: 'Clear the canvas',
      description: 'Empties the canvas. Existing app state and embedded files are preserved.',
    },
    async () => {
      clearCanvasFromServer();
      return { content: [{ type: 'text', text: 'Canvas cleared.' }] };
    },
  );

  server.registerTool(
    'screenshot_canvas',
    {
      title: 'See the canvas',
      description:
        "Returns the current Excalidraw canvas as a rendered image (vs. `get_canvas_state`'s scene JSON), so you can actually see what the user has drawn — including embedded screenshots whose bytes `get_canvas_state` strips. Reflects the live browser canvas at call time, with no debounce window. Safe to call in a loop. Defaults to a JPEG ~1024px on the longest side, which is plenty for vision and keeps round-trips fast; pass `maxDim` (up to 4096) for more detail or a smaller value for faster polling, and `quality` (0.1–1) to tune JPEG compression.",
      inputSchema: {
        maxDim: z.number().int().positive().max(4096).optional(),
        quality: z.number().min(0.1).max(1).optional(),
      },
    },
    async ({ maxDim, quality }) => {
      try {
        const { mime, data } = await requestScreenshot({ maxDim, quality });
        return {
          content: [{ type: 'image', data, mimeType: mime }],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: `screenshot_canvas failed: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
        };
      }
    },
  );

  // Agent UI-control tools. These push commands over /ws/agent-cursor to the
  // browser; AgentCursorOverlay animates the cursor sprite and dispatches the
  // matching DOM events. `delivered: 0` means no browser is listening — the
  // model should surface that to the user rather than retry blindly.

  server.registerTool(
    'dom_inspect',
    {
      title: 'List interactive UI elements with their bounding rects',
      description:
        'ALWAYS call this before cursor_move/cursor_click when you do not have an exact CSS selector. Returns the visible interactive elements on the page (buttons, links, inputs, things with role=button, etc.) with their accessible names, visible text, roles, and pixel rects. The returned `center: {x,y}` of the chosen element is what you pass to cursor_click — that hits the target precisely instead of guessing coordinates.\n\nPass `query` to fuzzy-match against accessible name / text / role (e.g. `query: "send to claude"`). Pass `selector` to scope the search to a region (defaults to document.body). `limit` caps the result count (default 30, max 100). Elements are ranked: exact name match > startsWith > contains; without a query, in-viewport elements come first.',
      inputSchema: {
        query: z.string().optional(),
        selector: z.string().optional(),
        limit: z.number().int().positive().max(100).optional(),
      },
    },
    async ({ query, selector, limit }) => {
      try {
        const result = await requestInspect({ query, selector, limit });
        return {
          content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: `dom_inspect failed: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
        };
      }
    },
  );

  server.registerTool(
    'cursor_move',
    {
      title: 'Move the agent cursor',
      description:
        'Smoothly moves the on-screen agent cursor to a target. Pass `selector` (CSS selector — preferred) OR a `x`/`y` viewport coordinate pair. `durationMs` controls the animation length (default 350ms). Use this to draw the user\'s eye before clicking, or just to inspect a region.',
      inputSchema: {
        selector: z.string().optional(),
        x: z.number().optional(),
        y: z.number().optional(),
        durationMs: z.number().int().positive().max(5000).optional(),
      },
    },
    async ({ selector, x, y, durationMs }) => {
      if (!selector && (typeof x !== 'number' || typeof y !== 'number')) {
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: 'cursor_move requires either `selector` or both `x` and `y`.',
            },
          ],
        };
      }
      const { delivered } = pushCursorCommand({
        type: 'move',
        selector,
        x,
        y,
        durationMs,
      });
      return {
        content: [
          {
            type: 'text',
            text: `cursor_move dispatched to ${delivered} client(s).`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'cursor_click',
    {
      title: 'Click at the agent cursor target',
      description:
        'Moves the agent cursor to the target and dispatches a real DOM click (`mousedown`/`mouseup`/`click`). Pass `selector` (CSS selector — preferred) OR `x`/`y`. `button` defaults to "left". The click fires on whatever element is at that point, so React handlers fire normally.',
      inputSchema: {
        selector: z.string().optional(),
        x: z.number().optional(),
        y: z.number().optional(),
        button: z.enum(['left', 'right']).optional(),
      },
    },
    async ({ selector, x, y, button }) => {
      if (!selector && (typeof x !== 'number' || typeof y !== 'number')) {
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: 'cursor_click requires either `selector` or both `x` and `y`.',
            },
          ],
        };
      }
      const { delivered } = pushCursorCommand({
        type: 'click',
        selector,
        x,
        y,
        button,
      });
      return {
        content: [
          {
            type: 'text',
            text: `cursor_click dispatched to ${delivered} client(s).`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'cursor_type',
    {
      title: 'Type into a focusable element',
      description:
        'Types text into a target element. If `selector` is given the element is focused first; otherwise the currently-focused element receives the input. Best for HTML inputs and textareas. For typing into the in-app terminal, use `terminal_type` instead — it speaks directly to the PTY.',
      inputSchema: {
        text: z.string(),
        selector: z.string().optional(),
      },
    },
    async ({ text, selector }) => {
      const { delivered } = pushCursorCommand({ type: 'type', text, selector });
      return {
        content: [
          {
            type: 'text',
            text: `cursor_type dispatched ${text.length} char(s) to ${delivered} client(s).`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'remember_note',
    {
      title: 'Record a workspace memory note',
      description:
        'Append a one-line note to ./tango-memory.md so future sessions in this workspace pick it up. Use this when the user states a design decision, constraint, or piece of context worth remembering — e.g. "auth uses magic links, no passwords", "primary brand color is #4F46E5", "TODO: revisit empty-state copy after launch". `category` is one of: `decision` (a settled choice that should not be re-litigated), `context` (background fact about the project), `todo` (something to come back to). Keep `text` short and self-contained — the user will read these as bullet points later.',
      inputSchema: {
        category: z.enum(['decision', 'context', 'todo']),
        text: z.string().min(1).max(500),
      },
    },
    async ({ category, text }) => {
      recordNote(category, text);
      return {
        content: [
          {
            type: 'text',
            text: `Recorded ${category} note in tango-memory.md.`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'terminal_type',
    {
      title: 'Send a message to the terminal Claude session',
      description:
        'Types text into the in-app xterm terminal AND presses Return to submit it. The terminal is running `claude --dangerously-skip-permissions` in the workspace, so this is the way you ask the terminal-Claude session to do something — it is your delegation channel. The Return is automatic; only set `submit: false` if you specifically want to seed the prompt buffer without sending it (rare).',
      inputSchema: {
        text: z.string(),
        submit: z.boolean().optional().describe('Defaults to true. Set false only to seed the buffer without submitting.'),
      },
    },
    async ({ text, submit }) => {
      const willSubmit = submit !== false;
      const { delivered } = pushCursorCommand({
        type: 'terminal_type',
        text,
        submit: willSubmit,
      });
      return {
        content: [
          {
            type: 'text',
            text: `terminal_type dispatched ${text.length} char(s) (submit=${willSubmit}) to ${delivered} client(s).`,
          },
        ],
      };
    },
  );

  return server;
}

// Read the entire request body (POST /mcp arrives as JSON).
async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as ArrayBuffer));
  }
  if (chunks.length === 0) return undefined;
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return undefined;
  return JSON.parse(raw);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(body));
}

export function mountMcp(server: http.Server, mcpPath = '/mcp'): void {
  // session-id → (transport, mcpServer) so multiple clients can talk
  // simultaneously without sharing protocol state.
  const transports: Record<
    string,
    { transport: StreamableHTTPServerTransport; mcpServer: McpServer }
  > = {};

  const handleMcp = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const sessionId = req.headers['mcp-session-id'];
    const sid = Array.isArray(sessionId) ? sessionId[0] : sessionId;

    try {
      if (req.method === 'POST') {
        const body = await readJsonBody(req);

        if (sid && transports[sid]) {
          await transports[sid].transport.handleRequest(req, res, body);
          return;
        }

        if (!sid && isInitializeRequest(body)) {
          const mcpServer = buildServer();
          const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: () => randomUUID(),
            // DNS rebinding protection — we're localhost-only.
            enableDnsRebindingProtection: true,
            allowedHosts: ['localhost', '127.0.0.1', `localhost:${process.env.PORT ?? '3000'}`, `127.0.0.1:${process.env.PORT ?? '3000'}`],
            onsessioninitialized: (newSid) => {
              transports[newSid] = { transport, mcpServer };
            },
          });
          // Do NOT call mcpServer.close() here. The server's close() calls
          // transport.close(), which fires this onclose again — infinite
          // recursion. Dropping the session entry is enough; the McpServer
          // will be GC'd once nothing else references it.
          transport.onclose = () => {
            const closedSid = transport.sessionId;
            if (closedSid && transports[closedSid]) {
              delete transports[closedSid];
            }
          };
          await mcpServer.connect(transport);
          await transport.handleRequest(req, res, body);
          return;
        }

        sendJson(res, 400, {
          jsonrpc: '2.0',
          error: { code: -32000, message: 'Bad Request: invalid or missing session ID' },
          id: null,
        });
        return;
      }

      if (req.method === 'GET' || req.method === 'DELETE') {
        if (!sid || !transports[sid]) {
          res.statusCode = 400;
          res.end('Invalid or missing session ID');
          return;
        }
        await transports[sid].transport.handleRequest(req, res);
        return;
      }

      res.statusCode = 405;
      res.setHeader('Allow', 'POST, GET, DELETE');
      res.end('Method Not Allowed');
    } catch (err) {
      console.error('[mcp] request error', err);
      if (!res.headersSent) {
        sendJson(res, 500, {
          jsonrpc: '2.0',
          error: { code: -32603, message: 'Internal server error' },
          id: null,
        });
      }
    }
  };

  // Hook the existing 'request' listener: route /mcp prefix to MCP, fall
  // through to whatever Next handler the host registered for everything else.
  // We capture the existing listeners, remove them, install our shim, and
  // re-fire them for non-/mcp requests.
  const existingListeners = server.listeners('request') as Array<
    (req: IncomingMessage, res: ServerResponse) => void
  >;
  server.removeAllListeners('request');
  server.on('request', (req, res) => {
    if (req.url && (req.url === mcpPath || req.url.startsWith(`${mcpPath}?`) || req.url.startsWith(`${mcpPath}/`))) {
      void handleMcp(req, res);
      return;
    }
    for (const listener of existingListeners) listener(req, res);
  });
}
