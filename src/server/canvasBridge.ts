import { randomUUID } from 'node:crypto';
import type { WebSocket } from 'ws';
import { registerHook } from './serverHooks';

// Authoritative server-side cache of the Excalidraw scene. The browser is the
// source of truth for human edits (it ships snapshots up the WS); MCP tools
// are the source of truth for AI edits (they ship via the helpers below).
// Last-writer-wins; no CRDT.

export type CanvasElement = Record<string, unknown>;
export type CanvasAppState = Record<string, unknown>;
export type CanvasFiles = Record<string, unknown>;

type Cache = {
  elements: CanvasElement[];
  appState: CanvasAppState;
  files: CanvasFiles;
};

let cache: Cache = { elements: [], appState: {}, files: {} };
const sockets = new Set<WebSocket>();

// Register the reset hook once on module load so the route-handler graph
// (where setWorkspace runs) can clear the canvas and broadcast an empty
// scene to all open canvas WSes via the cross-context registry.
registerHook('resetCanvas', () => {
  cache = { elements: [], appState: {}, files: {} };
  const payload = JSON.stringify({
    type: 'set',
    elements: [],
    appState: {},
    files: {},
  });
  for (const ws of sockets) {
    try {
      ws.send(payload);
    } catch {
      // socket dying; cleanup will run
    }
  }
});

type SnapshotMsg = {
  type: 'snapshot';
  elements?: CanvasElement[];
  appState?: CanvasAppState;
  files?: CanvasFiles;
};
type ScreenshotResultMsg = {
  type: 'screenshot_result';
  requestId: string;
  mime?: string;
  data?: string;
  error?: string;
};
type ServerSetMsg = {
  type: 'set';
  elements: CanvasElement[];
  appState: CanvasAppState;
  files: CanvasFiles;
};
type ServerPatchMsg = {
  type: 'patch';
  mode: 'append';
  elements: CanvasElement[];
};
type ScreenshotRequestMsg = {
  type: 'screenshot_request';
  requestId: string;
  opts?: ScreenshotOpts;
};
type ClientMsg = SnapshotMsg | ScreenshotResultMsg;
type ServerMsg = ServerSetMsg | ServerPatchMsg | ScreenshotRequestMsg;

export type ScreenshotOpts = {
  mime?: string;
  quality?: number;
  maxDim?: number;
};
export type ScreenshotResult = { mime: string; data: string };

type Pending = {
  resolve: (value: ScreenshotResult) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};
const pending = new Map<string, Pending>();

function broadcast(msg: ServerMsg): void {
  const payload = JSON.stringify(msg);
  for (const ws of sockets) {
    try {
      ws.send(payload);
    } catch {
      // socket dying; cleanup runs on close/error
    }
  }
}

export function attachCanvas(ws: WebSocket): void {
  sockets.add(ws);

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

  ws.on('message', (raw, isBinary) => {
    if (isBinary) return; // binary reserved for future use
    let parsed: ClientMsg;
    try {
      parsed = JSON.parse(raw.toString()) as ClientMsg;
    } catch {
      return;
    }
    if (parsed.type === 'snapshot') {
      cache = {
        elements: parsed.elements ?? [],
        appState: parsed.appState ?? {},
        files: parsed.files ?? {},
      };
      return;
    }
    if (parsed.type === 'screenshot_result') {
      const slot = pending.get(parsed.requestId);
      if (!slot) return;
      pending.delete(parsed.requestId);
      clearTimeout(slot.timer);
      if (parsed.error) {
        slot.reject(new Error(parsed.error));
        return;
      }
      if (!parsed.mime || !parsed.data) {
        slot.reject(new Error('screenshot_result missing mime/data'));
        return;
      }
      slot.resolve({ mime: parsed.mime, data: parsed.data });
    }
  });

  const cleanup = () => {
    sockets.delete(ws);
  };
  ws.on('close', cleanup);
  ws.on('error', cleanup);
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

function pickSocket(): WebSocket | null {
  for (const ws of sockets) {
    // ws.OPEN === 1; readyState may not always type the constants correctly.
    if (ws.readyState === 1) return ws;
  }
  return null;
}

export async function requestScreenshot(opts?: ScreenshotOpts & { timeoutMs?: number }): Promise<ScreenshotResult> {
  const ws = pickSocket();
  if (!ws) {
    throw new Error(
      'No browser connected to /ws/canvas — open the app in a tab and retry.',
    );
  }
  const requestId = randomUUID();
  const timeoutMs = opts?.timeoutMs ?? 3000;
  const renderOpts: ScreenshotOpts = {
    mime: opts?.mime,
    quality: opts?.quality,
    maxDim: opts?.maxDim,
  };

  return new Promise<ScreenshotResult>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`screenshot_canvas timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    pending.set(requestId, { resolve, reject, timer });
    try {
      ws.send(
        JSON.stringify({
          type: 'screenshot_request',
          requestId,
          opts: renderOpts,
        } satisfies ScreenshotRequestMsg),
      );
    } catch (err) {
      pending.delete(requestId);
      clearTimeout(timer);
      reject(err as Error);
    }
  });
}
