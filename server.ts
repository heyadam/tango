import http from 'node:http';
import next from 'next';
import { WebSocketServer } from 'ws';
import { attachPty } from './src/server/pty';
import { attachCanvas } from './src/server/canvasBridge';
import { attachAgentCursor } from './src/server/agentCursorBridge';
import { mountMcp } from './src/server/mcp';
import { WORKSPACE_DIR, ensureWorkspace } from './src/server/workspace';

const dev = process.env.NODE_ENV !== 'production';
const hostname = process.env.HOST ?? 'localhost';
const port = Number(process.env.PORT ?? 3000);

const app = next({ dev, hostname, port });

const TERMINAL_PATH = '/ws/terminal';
const CANVAS_PATH = '/ws/canvas';
const AGENT_CURSOR_PATH = '/ws/agent-cursor';

app.prepare().then(async () => {
  await ensureWorkspace(port);
  const handle = app.getRequestHandler();
  const upgradeHandle = app.getUpgradeHandler();

  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
      console.error('next handler error', err);
      res.statusCode = 500;
      res.end('internal server error');
    });
  });

  // mountMcp shims the 'request' listener: /mcp goes to MCP, everything else
  // falls through to the Next handler above.
  mountMcp(server);

  const wssTerminal = new WebSocketServer({ noServer: true });
  wssTerminal.on('connection', (ws) => {
    attachPty(ws);
  });

  const wssCanvas = new WebSocketServer({ noServer: true });
  wssCanvas.on('connection', (ws) => {
    attachCanvas(ws);
  });

  const wssAgentCursor = new WebSocketServer({ noServer: true });
  wssAgentCursor.on('connection', (ws) => {
    attachAgentCursor(ws);
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    if (url.pathname === TERMINAL_PATH) {
      wssTerminal.handleUpgrade(req, socket, head, (ws) => {
        wssTerminal.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === CANVAS_PATH) {
      wssCanvas.handleUpgrade(req, socket, head, (ws) => {
        wssCanvas.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === AGENT_CURSOR_PATH) {
      wssAgentCursor.handleUpgrade(req, socket, head, (ws) => {
        wssAgentCursor.emit('connection', ws, req);
      });
      return;
    }
    upgradeHandle(req, socket, head);
  });

  server.listen(port, () => {
    console.log(`▲ tango ready on http://${hostname}:${port}`);
    console.log(`  workspace: ${WORKSPACE_DIR}`);
  });
});
