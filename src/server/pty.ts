import os from 'node:os';
import * as pty from 'node-pty';
import type { WebSocket } from 'ws';

type ResizeMessage = { type: 'resize'; cols: number; rows: number };
type ControlMessage = ResizeMessage;

const defaultShell = (): string => {
  if (process.env.SHELL) return process.env.SHELL;
  if (process.platform === 'win32') return 'powershell.exe';
  return '/bin/zsh';
};

export function attachPty(ws: WebSocket): void {
  const shell = defaultShell();
  const ptyProcess = pty.spawn(shell, [], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: os.homedir(),
    env: {
      ...process.env,
      TERM: 'xterm-256color',
      COLORTERM: 'truecolor',
    },
  });

  let alive = true;

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
