import type { WebSocket } from 'ws';
import { registerHook } from './serverHooks';
import { createHub, createPendingMap } from './wsHub';
import type {
  CanvasAppState,
  CanvasClientMsg,
  CanvasElement,
  CanvasFiles,
  CanvasServerMsg,
  ScreenshotOpts,
  ScreenshotResult,
  ServerSetMsg,
} from '@/lib/canvasProtocol';

// Authoritative server-side cache of the Excalidraw scene. The browser is the
// source of truth for human edits (it ships snapshots up the WS); MCP tools
// are the source of truth for AI edits (they ship via the helpers below).
// Last-writer-wins; no CRDT. Wire types live in @/lib/canvasProtocol.

type Cache = {
  elements: CanvasElement[];
  appState: CanvasAppState;
  files: CanvasFiles;
};

let cache: Cache = { elements: [], appState: {}, files: {} };

const hub = createHub();
const screenshots = createPendingMap<ScreenshotResult>();

// Register the reset hook once on module load so the route-handler graph
// (where setWorkspace runs) can clear the canvas and broadcast an empty
// scene to all open canvas WSes via the cross-context registry.
registerHook('resetCanvas', () => {
  cache = { elements: [], appState: {}, files: {} };
  broadcast({ type: 'set', elements: [], appState: {}, files: {} });
});

function broadcast(msg: CanvasServerMsg): void {
  hub.broadcast(msg);
}

export function attachCanvas(ws: WebSocket): void {
  hub.attach(ws, {
    onMessage: (raw) => {
      const parsed = raw as CanvasClientMsg;
      if (parsed.type === 'snapshot') {
        cache = {
          elements: parsed.elements ?? [],
          appState: parsed.appState ?? {},
          files: parsed.files ?? {},
        };
        return;
      }
      if (parsed.type === 'screenshot_result') {
        if (parsed.error) {
          screenshots.reject(parsed.requestId, new Error(parsed.error));
          return;
        }
        if (!parsed.mime || !parsed.data) {
          screenshots.reject(
            parsed.requestId,
            new Error('screenshot_result missing mime/data'),
          );
          return;
        }
        screenshots.resolve(parsed.requestId, {
          mime: parsed.mime,
          data: parsed.data,
        });
      }
    },
  });

  // Send the current cache so a fresh client sees what AI has already drawn,
  // even if no other browser is open. The first browser's own `snapshot`
  // message will overwrite this with the localStorage-backed scene a moment
  // later — that's fine; user state wins on tie.
  try {
    ws.send(
      JSON.stringify({
        type: 'set',
        elements: cache.elements,
        appState: cache.appState,
        files: cache.files,
      } satisfies ServerSetMsg),
    );
  } catch {
    // socket already gone
  }
}

export function getCanvasState(): Cache {
  return cache;
}

export function setCanvasFromServer(
  elements: CanvasElement[],
  appState?: CanvasAppState,
  files?: CanvasFiles,
): void {
  cache = {
    elements,
    appState: appState ?? cache.appState,
    files: files ?? cache.files,
  };
  broadcast({
    type: 'set',
    elements: cache.elements,
    appState: cache.appState,
    files: cache.files,
  });
}

export function appendElementsFromServer(elements: CanvasElement[]): void {
  cache = { ...cache, elements: [...cache.elements, ...elements] };
  broadcast({ type: 'patch', mode: 'append', elements });
}

export function clearCanvasFromServer(): void {
  setCanvasFromServer([], cache.appState, cache.files);
}

export async function requestScreenshot(
  opts?: ScreenshotOpts & { timeoutMs?: number },
): Promise<ScreenshotResult> {
  const ws = hub.pickOpen();
  if (!ws) {
    throw new Error(
      'No browser connected to /ws/canvas — open the app in a tab and retry.',
    );
  }
  const renderOpts: ScreenshotOpts = {
    mime: opts?.mime,
    quality: opts?.quality,
    maxDim: opts?.maxDim,
  };
  const { id, promise } = screenshots.register({
    timeoutMs: opts?.timeoutMs ?? 3000,
    label: 'screenshot_canvas',
  });
  try {
    ws.send(
      JSON.stringify({
        type: 'screenshot_request',
        requestId: id,
        opts: renderOpts,
      } satisfies CanvasServerMsg),
    );
  } catch (err) {
    screenshots.reject(id, err as Error);
  }
  return promise;
}
