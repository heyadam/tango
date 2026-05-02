import type { WebSocket } from 'ws';
import { registerHook } from './serverHooks';
import { createHub } from './wsHub';
import {
  EMPTY_SPEC,
  type UIMockClientMsg,
  type UIMockServerMsg,
  type UINode,
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

export type UIMockDiagnostics = {
  frameOverflows: Array<{
    screenId: string;
    nodeId: string;
    axis: 'x' | 'y';
    overshoot: number;
  }>;
  emptyText: Array<{ screenId: string; nodeId: string; type: string }>;
};

// Types where missing/blank `text` is a concrete UX bug — the rendered shadcn
// primitive ends up label-less. `Input`/`Textarea` use `props.placeholder`
// instead, and `div` is decorative; both are excluded.
const TEXT_REQUIRED_TYPES = new Set<UINode['type']>([
  'text',
  'heading',
  'Button',
  'Badge',
]);

// Soft diagnostics for UI mock writes — surfaced on `set_ui_mock` /
// `add_ui_screen` so the model can self-correct without a follow-up
// `get_ui_mock` round-trip. Empty arrays mean "you're done."
export function analyzeUiSpec(spec: UISpec): UIMockDiagnostics {
  const frameOverflows: UIMockDiagnostics['frameOverflows'] = [];
  const emptyText: UIMockDiagnostics['emptyText'] = [];
  for (const screen of spec.screens) {
    for (const node of screen.nodes) {
      const overshootX = node.x + node.width - screen.frame.w;
      if (node.x < 0) {
        frameOverflows.push({
          screenId: screen.id,
          nodeId: node.id,
          axis: 'x',
          overshoot: -node.x,
        });
      } else if (overshootX > 0) {
        frameOverflows.push({
          screenId: screen.id,
          nodeId: node.id,
          axis: 'x',
          overshoot: overshootX,
        });
      }
      const overshootY = node.y + node.height - screen.frame.h;
      if (node.y < 0) {
        frameOverflows.push({
          screenId: screen.id,
          nodeId: node.id,
          axis: 'y',
          overshoot: -node.y,
        });
      } else if (overshootY > 0) {
        frameOverflows.push({
          screenId: screen.id,
          nodeId: node.id,
          axis: 'y',
          overshoot: overshootY,
        });
      }
      if (TEXT_REQUIRED_TYPES.has(node.type)) {
        const text = (node.text ?? '').trim();
        if (text === '') {
          emptyText.push({
            screenId: screen.id,
            nodeId: node.id,
            type: node.type,
          });
        }
      }
    }
  }
  return { frameOverflows, emptyText };
}

// Diagnostics for raw Excalidraw element batches (canvas tools). No implicit
// frame on the canvas, so frame-overflow is meaningless here — `emptyText` on
// `text` elements is the only check that consistently catches model errors
// (e.g. a placeholder element written with no `text` field at all).
export type CanvasDiagnostics = {
  emptyText: Array<{ id: string }>;
};

export function analyzeCanvasElements(
  elements: ReadonlyArray<Record<string, unknown>>,
): CanvasDiagnostics {
  const emptyText: CanvasDiagnostics['emptyText'] = [];
  for (const el of elements) {
    if (el.type !== 'text') continue;
    const text = typeof el.text === 'string' ? el.text.trim() : '';
    if (text === '') {
      emptyText.push({ id: typeof el.id === 'string' ? el.id : '<unknown>' });
    }
  }
  return { emptyText };
}
