import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import next from 'next';
import { WebSocketServer } from 'ws';
import { attachPty } from './src/server/pty';
import { attachAgent, warmAgentEngine } from './src/server/agentBridge';
import { attachUIMock, hydrateUIMockFromDisk } from './src/server/uiMockBridge';
import { flushPersistSync } from './src/server/uiMockPersist';
import { attachPreview } from './src/server/previewBridge';
import { mountMcp } from './src/server/mcp';
import { startSimHelper, stopSimHelper } from './src/server/sim';
import { ensureWorkspace, resolveWorkspaceAtBoot } from './src/server/workspace';
import {
  _setTerminalAgentInternal,
  loadPersistedTerminalAgent,
  loadPersistedWorkspace,
} from './src/server/workspaceState';

const dev = process.env.NODE_ENV !== 'production';
const hostname = process.env.HOST ?? 'localhost';
const port = Number(process.env.PORT ?? 3000);

// Expose port to API routes that need to write the right URL into managed
// .mcp.json on workspace selection. Set as early as possible — before we
// import setWorkspace / ensureWorkspace via the API routes.
process.env.TANGO_PORT = String(port);
// Expose the tango repo root so route-graph code can find in-repo assets
// (the preview-host Xcode project) regardless of process.cwd().
// fileURLToPath(import.meta.url), NOT import.meta.dirname — tsx's transform
// shims import.meta.url but leaves .dirname undefined.
const repoRoot = path.dirname(fileURLToPath(import.meta.url));
process.env.TANGO_REPO_ROOT = repoRoot;

// Pin the project root to this file's directory instead of inheriting
// process.cwd(). Launched from any other cwd (a git worktree, a parent dir,
// an IDE task), an implicit `dir` makes Next — and the Tailwind/PostCSS CSS
// pipeline — resolve `@import "tailwindcss"` from the wrong base and fail with
// "Can't resolve 'tailwindcss' in <parent dir>".
const app = next({ dev, hostname, port, dir: repoRoot });

const TERMINAL_PATH = '/ws/terminal';
const AGENT_PATH = '/ws/agent';
const UI_MOCK_PATH = '/ws/ui-mock';
const PREVIEW_PATH = '/ws/preview';

app.prepare().then(async () => {
  // Resolve the active workspace before anything else. Order:
  //   1. TANGO_WORKSPACE env var (pinned, picker locked)
  //   2. ~/.tango/state.json#lastWorkspace if it still exists
  //   3. null — picker will appear in the browser
  const resolved = await resolveWorkspaceAtBoot(loadPersistedWorkspace);
  _setTerminalAgentInternal(await loadPersistedTerminalAgent());
  if (resolved.path) {
    const ensure = await ensureWorkspace(port, resolved.path);
    if (!ensure.ok) {
      console.warn(
        `tango: workspace ${resolved.path} ensured with warnings:`,
        ensure.errors,
      );
    }
    // Restore the workspace's persisted design spec into the live cache so a
    // server restart doesn't lose the canvas.
    await hydrateUIMockFromDisk();
  }

  // Boot the iOS Simulator stream helper. No-op on non-darwin; failures
  // surface through /api/sim/status, not by crashing the server.
  startSimHelper();

  // Pre-warm the built-in agent engine so the first chat message doesn't pay
  // the subprocess cold start. Internally guarded: only runs when a workspace
  // is set and the 'tango' agent is selected.
  warmAgentEngine();

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
  // routing through SIGINT/SIGTERM. 'exit' is sync-only — stopSimHelper and
  // flushPersistSync are both sync.
  process.on('exit', () => {
    stopSimHelper();
    flushPersistSync();
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

  const wssTerminal = new WebSocketServer({ noServer: true });
  wssTerminal.on('connection', (ws, req) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    attachPty(ws, url.searchParams.get('agent'));
  });

  // Built-in agent chat panel (the 'tango' terminal agent) — structured JSON
  // frames to a Claude Agent SDK session instead of PTY bytes.
  const wssAgent = new WebSocketServer({ noServer: true });
  wssAgent.on('connection', (ws) => {
    attachAgent(ws);
  });

  const wssUIMock = new WebSocketServer({ noServer: true });
  wssUIMock.on('connection', (ws) => {
    attachUIMock(ws);
  });

  // The preview-host app in the iOS simulator connects here (the simulator
  // shares the host network stack, so ws://localhost works directly).
  const wssPreview = new WebSocketServer({ noServer: true });
  wssPreview.on('connection', (ws) => {
    attachPreview(ws);
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    if (url.pathname === TERMINAL_PATH) {
      wssTerminal.handleUpgrade(req, socket, head, (ws) => {
        wssTerminal.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === AGENT_PATH) {
      wssAgent.handleUpgrade(req, socket, head, (ws) => {
        wssAgent.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === UI_MOCK_PATH) {
      wssUIMock.handleUpgrade(req, socket, head, (ws) => {
        wssUIMock.emit('connection', ws, req);
      });
      return;
    }
    if (url.pathname === PREVIEW_PATH) {
      wssPreview.handleUpgrade(req, socket, head, (ws) => {
        wssPreview.emit('connection', ws, req);
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
