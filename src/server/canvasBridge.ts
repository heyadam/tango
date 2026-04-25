import type { WebSocket } from 'ws';

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

type SnapshotMsg = {
  type: 'snapshot';
  elements?: CanvasElement[];
  appState?: CanvasAppState;
  files?: CanvasFiles;
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
type ClientMsg = SnapshotMsg;
type ServerMsg = ServerSetMsg | ServerPatchMsg;

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
