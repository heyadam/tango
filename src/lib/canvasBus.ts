// Browser-side pub/sub seam for the canvas, mirroring terminalBus.
//
// SketchPanel owns the WebSocket to /ws/canvas and forwards:
//   - server frames in:  _emitApply(msg)  → DesignerCanvas applies via excalidrawAPI.updateScene
//   - local snapshots out: _onSnapshot(cb) → emits whenever the canvas debounces a change
// Other code in the app should not need to touch this.

// Excalidraw's appState contains Maps/Sets (`collaborators`, `pointers`,
// `followedBy`) that JSON.stringify silently flattens to `{}` / `{}` / `{}`.
// If those round-trip back into Excalidraw it crashes on `.forEach` /
// `.has` / `.size`. Strip them at every JSON boundary so Excalidraw rebuilds
// its defaults instead.
const NON_JSON_APPSTATE_KEYS = new Set(['collaborators', 'pointers', 'followedBy']);

export function sanitizeAppState<T extends Record<string, unknown> | undefined | null>(
  appState: T,
): T {
  if (!appState || typeof appState !== 'object') return appState;
  const cleaned: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(appState)) {
    if (NON_JSON_APPSTATE_KEYS.has(k)) continue;
    if (v instanceof Map || v instanceof Set) continue;
    cleaned[k] = v;
  }
  return cleaned as T;
}

export type ApplySetMsg = {
  type: 'set';
  elements: unknown[];
  appState?: Record<string, unknown>;
  files?: Record<string, unknown>;
};
export type ApplyPatchMsg = {
  type: 'patch';
  mode: 'append';
  elements: unknown[];
};
export type ApplyMsg = ApplySetMsg | ApplyPatchMsg;

export type LocalSnapshot = {
  elements: unknown[];
  appState: Record<string, unknown>;
  files: Record<string, unknown>;
};

type ApplyListener = (msg: ApplyMsg) => void;
type SnapshotListener = (snap: LocalSnapshot) => void;

const applyListeners = new Set<ApplyListener>();
const snapshotListeners = new Set<SnapshotListener>();

export const canvasBus = {
  // Wired by DesignerCanvas — receives server-driven updates.
  _onApply(cb: ApplyListener): () => void {
    applyListeners.add(cb);
    return () => applyListeners.delete(cb);
  },

  // Wired by SketchPanel — listens for local debounced snapshots to forward up the WS.
  _onSnapshot(cb: SnapshotListener): () => void {
    snapshotListeners.add(cb);
    return () => snapshotListeners.delete(cb);
  },

  _emitApply(msg: ApplyMsg): void {
    for (const fn of applyListeners) fn(msg);
  },

  _emitSnapshot(snap: LocalSnapshot): void {
    for (const fn of snapshotListeners) fn(snap);
  },
};

declare global {
  interface Window {
    __tangoCanvasBus?: typeof canvasBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoCanvasBus = canvasBus;
}
