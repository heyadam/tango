// /ws/preview hub: streams the RESOLVED design spec to the preview-host app
// running in the iOS simulator. The app is deliberately dumb — no Tailwind,
// no theme tokens, no CSS — so everything is flattened through resolveSpec()
// (shared with the SwiftUI codegen) before it crosses the wire.
//
// Wire format (JSON text frames, versioned):
//   server → app: { v: 1, type: 'spec', activeScreenId, spec: ResolvedSpec }
//   server → app: { v: 1, type: 'show_screen', screenId }
//   app → server: { type: 'hello', client, version }   (logged only, today)
//
// uiMockBridge imports this module (never the reverse) and calls
// broadcastPreviewSpec from its cacheChanged choke point, so every spec
// mutation — browser drag, MCP edit, hydration — reaches the simulator in
// the same frame it reaches the browsers.

import type { WebSocket } from 'ws';
import { createHub } from './wsHub';
import { registerHook } from './serverHooks';
import { resolveSpec } from '@/lib/uiResolve';
import type { UISpec } from '@/lib/uiMockProtocol';

const hub = createHub();

// Latest frame, resent to every newly attached client so a (re)connecting
// preview app immediately shows the current design.
let lastFrame: string | null = null;

export function attachPreview(ws: WebSocket): void {
  hub.attach(ws, {
    onMessage: (parsed) => {
      const msg = parsed as { type?: string; client?: string };
      if (msg.type === 'hello') {
        console.log(`[preview] client connected: ${msg.client ?? 'unknown'}`);
      }
    },
  });
  if (lastFrame) {
    try {
      ws.send(lastFrame);
    } catch {
      // socket already gone
    }
  }
}

export function broadcastPreviewSpec(
  spec: UISpec,
  activeScreenId: string | null,
): void {
  lastFrame = JSON.stringify({
    v: 1,
    type: 'spec',
    activeScreenId,
    spec: resolveSpec(spec),
  });
  for (const ws of hub.sockets) {
    try {
      ws.send(lastFrame);
    } catch {
      // socket dying; hub cleanup runs on close/error
    }
  }
}

export function broadcastShowScreen(screenId: string): void {
  hub.broadcast({ v: 1, type: 'show_screen', screenId });
}

export function previewClientCount(): number {
  return hub.sockets.size;
}

registerHook('previewClientCount', previewClientCount);
