import { randomUUID } from 'node:crypto';
import type { WebSocket } from 'ws';

// Bridge that carries agent-driven UI actions from server-side MCP tools to
// the browser. Cursor moves/clicks/typing are dispatched via DOM events by
// AgentCursorOverlay; terminal_type is forwarded via terminalBus into the
// existing /ws/terminal pipeline. dom_inspect is the one round-trip caller —
// it sends an `inspect` request and awaits an `inspect_result` reply.

export type CursorMoveCmd = {
  type: 'move';
  selector?: string;
  x?: number;
  y?: number;
  durationMs?: number;
};

export type CursorClickCmd = {
  type: 'click';
  selector?: string;
  x?: number;
  y?: number;
  button?: 'left' | 'right';
};

export type CursorTypeCmd = {
  type: 'type';
  text: string;
  selector?: string;
};

export type TerminalTypeCmd = {
  type: 'terminal_type';
  text: string;
  submit?: boolean;
};

export type AgentCommand =
  | CursorMoveCmd
  | CursorClickCmd
  | CursorTypeCmd
  | TerminalTypeCmd;

export type InteractiveElement = {
  role: string;
  name: string;
  text: string;
  rect: { x: number; y: number; width: number; height: number };
  center: { x: number; y: number };
  selector?: string;
  inViewport: boolean;
  disabled: boolean;
};

export type InspectResult = {
  total: number;
  returned: number;
  viewport: { width: number; height: number };
  elements: InteractiveElement[];
};

const sockets = new Set<WebSocket>();

type Pending = {
  resolve: (value: InspectResult) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};
const pending = new Map<string, Pending>();

export function attachAgentCursor(ws: WebSocket): void {
  sockets.add(ws);

  ws.on('message', (raw, isBinary) => {
    if (isBinary) return;
    let parsed: { type?: string; requestId?: string; result?: InspectResult; error?: string };
    try {
      parsed = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (parsed.type !== 'inspect_result' || !parsed.requestId) return;
    const slot = pending.get(parsed.requestId);
    if (!slot) return;
    pending.delete(parsed.requestId);
    clearTimeout(slot.timer);
    if (parsed.error) {
      slot.reject(new Error(parsed.error));
      return;
    }
    if (!parsed.result) {
      slot.reject(new Error('inspect_result missing result'));
      return;
    }
    slot.resolve(parsed.result);
  });

  const cleanup = () => {
    sockets.delete(ws);
  };
  ws.on('close', cleanup);
  ws.on('error', cleanup);
}

export function pushCursorCommand(cmd: AgentCommand): { delivered: number } {
  const payload = JSON.stringify(cmd);
  let delivered = 0;
  for (const ws of sockets) {
    try {
      ws.send(payload);
      delivered += 1;
    } catch {
      // socket dying; cleanup runs on close/error
    }
  }
  return { delivered };
}

function pickSocket(): WebSocket | null {
  for (const ws of sockets) {
    // ws.OPEN === 1, but the type isn't always exposed. Just compare to 1.
    if (ws.readyState === 1) return ws;
  }
  return null;
}

export async function requestInspect(opts: {
  query?: string;
  selector?: string;
  limit?: number;
  timeoutMs?: number;
}): Promise<InspectResult> {
  const ws = pickSocket();
  if (!ws) {
    throw new Error(
      'No browser connected to /ws/agent-cursor — open the app in a tab and retry.',
    );
  }
  const requestId = randomUUID();
  const timeoutMs = opts.timeoutMs ?? 3000;

  return new Promise<InspectResult>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`dom_inspect timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
    try {
      ws.send(
        JSON.stringify({
          type: 'inspect',
          requestId,
          query: opts.query,
          selector: opts.selector,
          limit: opts.limit ?? 30,
        }),
      );
    } catch (err) {
      pending.delete(requestId);
      clearTimeout(timer);
      reject(err as Error);
    }
  });
}
