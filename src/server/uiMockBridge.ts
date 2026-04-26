import type { WebSocket } from 'ws';
import { registerHook } from './serverHooks';
import { createHub } from './wsHub';
import {
  EMPTY_SPEC,
  type UIMockClientMsg,
  type UIMockServerMsg,
  type UIScreen,
  type UISpec,
} from '@/lib/uiMockProtocol';

// Authoritative server-side cache of the UI mock spec — sibling of
// canvasBridge for the new "UI" mode. The browser is the source of truth for
// human edits (drag/resize/text snapshots ship up the WS); MCP tools are the
// source of truth for AI edits (set/append helpers below). Last-writer-wins.

let cache: UISpec = EMPTY_SPEC;

const hub = createHub();

// Cleared by setWorkspace via the cross-context registry (route handlers live
// in a different module graph; see serverHooks.ts).
registerHook('resetUiMock', () => {
  cache = { screens: [] };
  broadcast({ type: 'set', spec: cache });
});

function broadcast(msg: UIMockServerMsg): void {
  hub.broadcast(msg);
}

export function attachUIMock(ws: WebSocket): void {
  hub.attach(ws, {
    onMessage: (raw) => {
      const parsed = raw as UIMockClientMsg;
      if (parsed.type === 'snapshot' && parsed.spec) {
        cache = parsed.spec;
      }
    },
  });

  // Send the current cache so a fresh client sees what AI has already written,
  // even if no other browser is open. The browser's own snapshot a moment
  // later will overwrite this with its localStorage-backed spec — fine, user
  // state wins on tie.
  try {
    ws.send(
      JSON.stringify({ type: 'set', spec: cache } satisfies UIMockServerMsg),
    );
  } catch {
    // socket already gone
  }
}

export function getUIMock(): UISpec {
  return cache;
}

export function setUIMockFromServer(spec: UISpec): void {
  cache = spec;
  broadcast({ type: 'set', spec });
}

export function appendUIScreenFromServer(screen: UIScreen): void {
  cache = { ...cache, screens: [...cache.screens, screen] };
  broadcast({ type: 'append_screen', screen });
}

export function clearUIMockFromServer(): void {
  setUIMockFromServer({ screens: [] });
}
