import http from 'node:http';
import next from 'next';
import { WebSocketServer } from 'ws';
import { attachCanvas } from './src/server/canvasBridge';
import { attachUIMock } from './src/server/uiMockBridge';
import { mountMcp } from './src/server/mcp';
import { startSimHelper, stopSimHelper } from './src/server/sim';
import { ensureWorkspace, resolveWorkspaceAtBoot } from './src/server/workspace';
import { loadPersistedWorkspace } from './src/server/workspaceState';

const dev = process.env.NODE_ENV !== 'production';
const hostname = process.env.HOST ?? 'localhost';
const port = Number(process.env.PORT ?? 3000);

// Expose port to API routes that need to write the right URL into managed
// .mcp.json on workspace selection. Set as early as possible — before we
// import setWorkspace / ensureWorkspace via the API routes.
process.env.TANGO_PORT = String(port);

const app = next({ dev, hostname, port });

const CANVAS_PATH = '/ws/canvas';
const UI_MOCK_PATH = '/ws/ui-mock';

app.prepare().then(async () => {
  // Resolve the active workspace before anything else. Order:
  //   1. TANGO_WORKSPACE env var (pinned, picker locked)
  //   2. ~/.tango/state.json#lastWorkspace if it still exists
  //   3. null — picker will appear in the browser
  const resolved = await resolveWorkspaceAtBoot(loadPersistedWorkspace);
  if (resolved.path) {
    const ensure = await ensureWorkspace(port, resolved.path);
    if (!ensure.ok) {
      console.warn(
        `tango: workspace ${resolved.path} ensured with warnings:`,
        ensure.errors,
      );
    }
  }

  // Boot the iOS Simulator stream helper. No-op on non-darwin; failures
  // surface through /api/sim/status, not by crashing the server.
  startSimHelper();

  let shuttingDown = false;
  const onShutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    stopSimHelper();
    process.exit(0);
  };
  process.on('SIGINT', onShutdown);
  process.on('SIGTERM', onShutdown);
  // Belt-and-suspenders for tsx hot-reload and any path that exits without
  // routing through SIGINT/SIGTERM. 'exit' is sync-only — stopSimHelper is sync.
  process.on('exit', () => {
    stopSimHelper();
  });

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

  const wssCanvas = new WebSocketServer({ noServer: true });
  wssCanvas.on('connection', (ws) => {
    attachCanvas(ws);
  });

  const wssUIMock = new WebSocketServer({ noServer: true });
  wssUIMock.on('connection', (ws) => {
    attachUIMock(ws);
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    if (url.pathname === CANVAS_PATH) {
      wssCanvas.handleUpgrade(req, socket, head, (ws) => {
        wssCanvas.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === UI_MOCK_PATH) {
      wssUIMock.handleUpgrade(req, socket, head, (ws) => {
        wssUIMock.emit('connection', ws, req);
      });
      return;
    }
    upgradeHandle(req, socket, head);
  });

  server.listen(port, () => {
    console.log(`▲ tango ready on http://${hostname}:${port}`);
    if (resolved.path) {
      console.log(`  workspace: ${resolved.path} (${resolved.source})`);
    } else {
      console.log('  workspace: unset — open the app in a browser to pick one');
    }
  });
});
