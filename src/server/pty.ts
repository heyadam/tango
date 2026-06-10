import * as pty from 'node-pty';
import type { WebSocket } from 'ws';
import { getWorkspaceOrNull } from './workspace';
import { getTerminalAgent } from './workspaceState';
import { registerHook } from './serverHooks';
import { tangoPort } from './config';
import { buildTerminalPtyEnv } from './ptyEnv';
import {
  terminalAgentFromQuery,
  terminalAgentLaunchCommand,
} from './terminalAgent';
import { createHub } from './wsHub';

type ResizeMessage = { type: 'resize'; cols: number; rows: number };
type ControlMessage = ResizeMessage;

// Active terminal sockets — tracked so workspace switches can broadcast a
// JSON control frame to every browser-side terminal so they can reconnect.
const hub = createHub();

// Register the broadcast hook once on module load so the route-handler graph
// can reach this Set via the cross-context registry. See serverHooks.ts.
registerHook('broadcastWorkspaceChanged', () => {
  hub.broadcast({ type: 'workspace_changed' });
});

registerHook('broadcastTerminalAgentChanged', () => {
  hub.broadcast({ type: 'terminal_agent_changed', agent: getTerminalAgent() });
});

const defaultShell = (): string => {
  if (process.env.SHELL) return process.env.SHELL;
  if (process.platform === 'win32') return 'powershell.exe';
  return '/bin/zsh';
};

export function attachPty(ws: WebSocket, requestedAgent?: unknown): void {
  const workspace = getWorkspaceOrNull();
  if (workspace == null) {
    // No workspace selected — refuse to spawn a shell into "nowhere." We send
    // a textual ANSI banner so the user sees something in xterm, and close
    // with a custom code carrying the reason.
    try {
      ws.send(
        Buffer.from(
          '\r\n\x1b[33m[no workspace selected — pick a project folder]\x1b[0m\r\n',
          'utf8',
        ),
        { binary: true },
      );
    } catch {
      // socket already gone
    }
    try {
      ws.close(4001, 'no workspace selected');
    } catch {
      // already closed
    }
    return;
  }
  const shell = defaultShell();
  const agent = terminalAgentFromQuery(requestedAgent) ?? getTerminalAgent();
  const port = tangoPort();
  const ptyProcess = pty.spawn(shell, [], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: workspace,
    env: buildTerminalPtyEnv(workspace, port),
  });

  let alive = true;
  hub.attach(ws);

  // Auto-launch the selected terminal agent on every fresh PTY. The shell
  // still runs first, then this command queues into stdin and executes once
  // the prompt appears. \r is the TTY "Enter."
  ptyProcess.write(`${terminalAgentLaunchCommand(agent, port)}\r`);

  const onDataDisposable = ptyProcess.onData((data) => {
    if (!alive) return;
    try {
      ws.send(Buffer.from(data, 'utf8'), { binary: true });
    } catch {
      // socket closed mid-write
    }
  });

  const onExitDisposable = ptyProcess.onExit(({ exitCode }) => {
    alive = false;
    try {
      ws.close(1000, `pty exited (${exitCode})`);
    } catch {
      // already closed
    }
  });

  ws.on('message', (msg, isBinary) => {
    if (!alive) return;
    if (isBinary) {
      const buf = Array.isArray(msg) ? Buffer.concat(msg) : (msg as Buffer);
      ptyProcess.write(buf.toString('utf8'));
      return;
    }
    let parsed: ControlMessage;
    try {
      parsed = JSON.parse(msg.toString()) as ControlMessage;
    } catch {
      return;
    }
    if (parsed.type === 'resize') {
      const cols = Math.max(1, Math.floor(parsed.cols));
      const rows = Math.max(1, Math.floor(parsed.rows));
      try {
        ptyProcess.resize(cols, rows);
      } catch {
        // pty may have already exited
      }
    }
  });

  // hub.attach already removes ws from the broadcast set on close/error; we
  // just need to tear down the PTY-specific resources.
  const cleanup = () => {
    if (!alive) return;
    alive = false;
    onDataDisposable.dispose();
    onExitDisposable.dispose();
    try {
      ptyProcess.kill();
    } catch {
      // already dead
    }
  };

  ws.on('close', cleanup);
  ws.on('error', cleanup);
}
