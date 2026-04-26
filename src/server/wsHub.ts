import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';

// Shared WebSocket fan-out + round-trip-RPC primitives. Three bridges (pty,
// canvas, agent-cursor) used to re-implement the same Set<WebSocket>,
// broadcast loop, open-socket picker, and pending-map+timeout pattern; this
// module is the single home for that boilerplate. Callers wire their own
// per-message handler and any first-frame send.

type MessageHandler = (parsed: unknown, ws: WebSocket) => void;

export type WSHub = {
  readonly sockets: ReadonlySet<WebSocket>;
  attach(ws: WebSocket, opts?: { onMessage?: MessageHandler }): void;
  broadcast(msg: unknown): void;
  pickOpen(): WebSocket | null;
};

export function createHub(): WSHub {
  const sockets = new Set<WebSocket>();

  const attach: WSHub['attach'] = (ws, opts) => {
    sockets.add(ws);
    if (opts?.onMessage) {
      const onMessage = opts.onMessage;
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return;
        let parsed: unknown;
        try {
          parsed = JSON.parse(raw.toString());
        } catch {
          return;
        }
        onMessage(parsed, ws);
      });
    }
    const cleanup = () => {
      sockets.delete(ws);
    };
    ws.on('close', cleanup);
    ws.on('error', cleanup);
  };

  const broadcast: WSHub['broadcast'] = (msg) => {
    const payload = JSON.stringify(msg);
    for (const ws of sockets) {
      try {
        ws.send(payload);
      } catch {
        // socket dying; cleanup runs on close/error
      }
    }
  };

  const pickOpen: WSHub['pickOpen'] = () => {
    for (const ws of sockets) {
      if (ws.readyState === WebSocket.OPEN) return ws;
    }
    return null;
  };

  return { sockets, attach, broadcast, pickOpen };
}

// Request/reply correlation for round-trip MCP tools (dom_inspect,
// screenshot_canvas). Caller sends `id` over the wire and resolves/rejects
// when the matching reply arrives; a timer auto-rejects if it doesn't.
export type PendingMap<T> = {
  register(opts: { timeoutMs: number; label: string }): {
    id: string;
    promise: Promise<T>;
  };
  resolve(id: string, value: T): boolean;
  reject(id: string, err: Error): boolean;
};

export function createPendingMap<T>(): PendingMap<T> {
  type Slot = {
    resolve: (v: T) => void;
    reject: (e: Error) => void;
    timer: NodeJS.Timeout;
  };
  const pending = new Map<string, Slot>();

  return {
    register({ timeoutMs, label }) {
      const id = randomUUID();
      const promise = new Promise<T>((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`${label} timed out after ${timeoutMs}ms`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
      });
      return { id, promise };
    },
    resolve(id, value) {
      const slot = pending.get(id);
      if (!slot) return false;
      pending.delete(id);
      clearTimeout(slot.timer);
      slot.resolve(value);
      return true;
    },
    reject(id, err) {
      const slot = pending.get(id);
      if (!slot) return false;
      pending.delete(id);
      clearTimeout(slot.timer);
      slot.reject(err);
      return true;
    },
  };
}
