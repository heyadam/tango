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

// Last apply message — replayed to new subscribers. UIMockCanvas is dynamic-
// imported (react-moveable touches `window` at module load), and UIPanel
// opens the WS the moment its outer shell mounts. If the bridge sends its
// initial `set` while the canvas chunk is still loading, the message would
// be dropped on the floor; replay closes that window without coupling
// UIPanel to the canvas's mount lifecycle.
let lastApply: ApplyMsg | null = null;

export const uiMockBus = {
  // Wired by UIMockCanvas — receives server-driven updates (set / append).
  _onApply(cb: ApplyListener): () => void {
    applyListeners.add(cb);
    if (lastApply) {
      try {
        cb(lastApply);
      } catch {
        // listener threw; we still want to keep it registered
      }
    }
    return () => applyListeners.delete(cb);
  },

  // Wired by UIPanel — listens for local debounced snapshots to forward up
  // the WS.
  _onSnapshot(cb: SnapshotListener): () => void {
    snapshotListeners.add(cb);
    return () => snapshotListeners.delete(cb);
  },

  _emitApply(msg: ApplyMsg): void {
    lastApply = msg;
    for (const fn of applyListeners) fn(msg);
  },

  _emitSnapshot(spec: UISpec): void {
    for (const fn of snapshotListeners) fn(spec);
  },

  // Called by UIPanel on workspace switch so a fresh mount doesn't replay
  // the previous workspace's spec.
  _resetForWorkspaceSwitch(): void {
    lastApply = null;
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
