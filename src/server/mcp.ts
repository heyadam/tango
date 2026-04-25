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
  setCanvasFromServer,
  type CanvasElement,
} from './canvasBridge';

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
          transport.onclose = () => {
            const closedSid = transport.sessionId;
            if (closedSid && transports[closedSid]) {
              delete transports[closedSid];
            }
            void mcpServer.close();
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
