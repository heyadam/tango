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
// Live pixel size of the browser's UI panel render area, pushed up the WS by
// UIPanel on mount + debounced resize. Surfaced to Claude via `get_ui_viewport`
// so new screens default to "what the user actually sees" instead of a
// hardcoded form-factor size. `null` until the first browser connects.
let viewport: { w: number; h: number } | null = null;

const hub = createHub();

// Cleared by setWorkspace via the cross-context registry (route handlers live
// in a different module graph; see serverHooks.ts).
registerHook('resetUiMock', () => {
  cache = { screens: [] };
  viewport = null;
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
      } else if (parsed.type === 'viewport') {
        const w = Math.round(parsed.w);
        const h = Math.round(parsed.h);
        if (Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0) {
          viewport = { w, h };
        }
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

export function getUIViewport(): { w: number; h: number } | null {
  return viewport;
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
