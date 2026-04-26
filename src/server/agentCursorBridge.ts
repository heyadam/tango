import type { WebSocket } from 'ws';
import { createHub, createPendingMap } from './wsHub';
import type {
  AgentCommand,
  InspectResult,
  InspectResultMsg,
} from '@/lib/agentCursorProtocol';

// Bridge that carries agent-driven UI actions from server-side MCP tools to
// the browser. Cursor moves/clicks/typing are dispatched via DOM events by
// AgentCursorOverlay; terminal_type is forwarded via terminalBus into the
// existing /ws/terminal pipeline. dom_inspect is the one round-trip caller —
// it sends an `inspect` request and awaits an `inspect_result` reply.

const hub = createHub();
const inspects = createPendingMap<InspectResult>();

export function attachAgentCursor(ws: WebSocket): void {
  hub.attach(ws, {
    onMessage: (raw) => {
      const parsed = raw as Partial<InspectResultMsg>;
      if (parsed.type !== 'inspect_result' || !parsed.requestId) return;
      if (parsed.error) {
        inspects.reject(parsed.requestId, new Error(parsed.error));
        return;
      }
      if (!parsed.result) {
        inspects.reject(
          parsed.requestId,
          new Error('inspect_result missing result'),
        );
        return;
      }
      inspects.resolve(parsed.requestId, parsed.result);
    },
  });
}

export function pushCursorCommand(cmd: AgentCommand): { delivered: number } {
  const payload = JSON.stringify(cmd);
  let delivered = 0;
  for (const ws of hub.sockets) {
    try {
      ws.send(payload);
      delivered += 1;
    } catch {
      // socket dying; cleanup runs on close/error
    }
  }
  return { delivered };
}

export async function requestInspect(opts: {
  query?: string;
  selector?: string;
  limit?: number;
  timeoutMs?: number;
}): Promise<InspectResult> {
  const ws = hub.pickOpen();
  if (!ws) {
    throw new Error(
      'No browser connected to /ws/agent-cursor — open the app in a tab and retry.',
    );
  }
  const { id, promise } = inspects.register({
    timeoutMs: opts.timeoutMs ?? 3000,
    label: 'dom_inspect',
  });
  try {
    ws.send(
      JSON.stringify({
        type: 'inspect',
        requestId: id,
        query: opts.query,
        selector: opts.selector,
        limit: opts.limit ?? 30,
      }),
    );
  } catch (err) {
    inspects.reject(id, err as Error);
  }
  return promise;
}
