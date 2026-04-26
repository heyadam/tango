// Browser-side pub/sub seam for the UI mock, sibling of canvasBus.
//
// UIPanel owns the WebSocket to /ws/ui-mock and forwards:
//   - server frames in:    _emitApply(msg) → UIMockCanvas applies via setSpec
//   - local snapshots out: _onSnapshot(cb) → emits whenever the canvas
//                          debounces a change (drag end / text edit / etc.)
// Other code in the app should not need to touch this.

import type { UIMockServerMsg, UISpec } from './uiMockProtocol';

export type ApplyMsg = UIMockServerMsg;

type ApplyListener = (msg: ApplyMsg) => void;
type SnapshotListener = (spec: UISpec) => void;

const applyListeners = new Set<ApplyListener>();
const snapshotListeners = new Set<SnapshotListener>();

export const uiMockBus = {
  // Wired by UIMockCanvas — receives server-driven updates (set / append).
  _onApply(cb: ApplyListener): () => void {
    applyListeners.add(cb);
    return () => applyListeners.delete(cb);
  },

  // Wired by UIPanel — listens for local debounced snapshots to forward up
  // the WS.
  _onSnapshot(cb: SnapshotListener): () => void {
    snapshotListeners.add(cb);
    return () => snapshotListeners.delete(cb);
  },

  _emitApply(msg: ApplyMsg): void {
    for (const fn of applyListeners) fn(msg);
  },

  _emitSnapshot(spec: UISpec): void {
    for (const fn of snapshotListeners) fn(spec);
  },
};

declare global {
  interface Window {
    __tangoUiMockBus?: typeof uiMockBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoUiMockBus = uiMockBus;
}
