'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import type { ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { sketchStore } from '@/lib/sketchStore';
import { canvasBus, sanitizeAppState, type ApplyMsg } from '@/lib/canvasBus';
import type { ScreenshotRequestMsg } from '@/lib/canvasProtocol';
import { workspaceBus } from '@/lib/workspaceBus';
import { openWS } from '@/lib/wsClient';
import type { DesignerHandles } from './DesignerCanvas';

const DesignerCanvas = dynamic(() => import('./DesignerCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-background" />,
});

type LoadState =
  | { status: 'loading' }
  | { status: 'ready'; initialData: ExcalidrawInitialDataState | null };

// Chunked Uint8Array → base64 — String.fromCharCode(...bigArray) overflows the
// argument stack on large images.
function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

type Props = {
  onCanvasReady?: (handles: DesignerHandles) => void;
};

export default function SketchPanel({ onCanvasReady }: Props) {
  const handlesRef = useRef<DesignerHandles | null>(null);
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });
  // Bumping this counter remounts DesignerCanvas (and re-runs the WS effect)
  // so a workspace switch starts from a clean slate.
  const [generation, setGeneration] = useState(0);

  // On workspace switch: drop the local cache so the new workspace's canvas
  // starts empty (the server's canvasBridge has already been cleared by
  // setWorkspace), then bump generation to remount.
  useEffect(() => {
    return workspaceBus.subscribe(() => {
      sketchStore.setCurrent(
        JSON.stringify({
          type: 'excalidraw',
          version: 2,
          source: 'tango',
          elements: [],
          appState: {},
          files: {},
        }),
      );
      setLoad({ status: 'loading' });
      setGeneration((g) => g + 1);
    });
  }, []);

  useEffect(() => {
    const raw = sketchStore.getCurrent();
    let parsed: ExcalidrawInitialDataState | null = null;
    if (raw) {
      try {
        parsed = JSON.parse(raw) as ExcalidrawInitialDataState;
        if (parsed && parsed.appState) {
          // Old localStorage may contain a corrupted `collaborators: {}` — strip
          // it so Excalidraw rebuilds its Map default instead of crashing.
          parsed.appState = sanitizeAppState(
            parsed.appState as unknown as Record<string, unknown>,
          ) as typeof parsed.appState;
        }
      } catch {
        parsed = null;
      }
    }
    setLoad({ status: 'ready', initialData: parsed });
  }, [generation]);

  // After a (re)mount — e.g. switching back from Moodboard mode — kick
  // Excalidraw's ResizeObserver so the canvas re-measures against its current
  // container instead of keeping a stale width.
  useEffect(() => {
    if (load.status !== 'ready') return;
    const id = requestAnimationFrame(() => {
      window.dispatchEvent(new Event('resize'));
    });
    return () => cancelAnimationFrame(id);
  }, [load.status]);

  const wsRef = useRef<WebSocket | null>(null);

  const onPersist = useCallback((json: string) => {
    sketchStore.setCurrent(json);
  }, []);

  const handleReady = useCallback(
    (handles: DesignerHandles) => {
      handlesRef.current = handles;
      onCanvasReady?.(handles);
    },
    [onCanvasReady],
  );

  // Open the canvas WS bridge. Locally-debounced snapshots from the canvas
  // (forwarded via canvasBus) ship up to the server cache; server frames apply
  // back into Excalidraw via canvasBus._emitApply, which DesignerCanvas owns.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const ws = openWS('/ws/canvas');
    wsRef.current = ws;

    const offSnapshot = canvasBus._onSnapshot((snap) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: 'snapshot', ...snap }));
      } catch {
        // socket dying
      }
    });

    const respondToScreenshot = async (req: ScreenshotRequestMsg) => {
      const reply = (
        body: { mime: string; data: string } | { error: string },
      ) => {
        if (ws.readyState !== WebSocket.OPEN) return;
        try {
          ws.send(
            JSON.stringify({
              type: 'screenshot_result',
              requestId: req.requestId,
              ...body,
            }),
          );
        } catch {
          // socket dying
        }
      };
      const handles = handlesRef.current;
      if (!handles) {
        reply({ error: 'Canvas not ready yet — try again in a moment.' });
        return;
      }
      try {
        const { mime, bytes } = await handles.getImage(req.opts);
        reply({ mime, data: bytesToBase64(bytes) });
      } catch (err) {
        reply({
          error: err instanceof Error ? err.message : String(err),
        });
      }
    };

    ws.addEventListener('message', (ev) => {
      let parsed: ApplyMsg | ScreenshotRequestMsg;
      try {
        parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : '') as
          | ApplyMsg
          | ScreenshotRequestMsg;
      } catch {
        return;
      }
      if (parsed.type === 'screenshot_request') {
        void respondToScreenshot(parsed);
        return;
      }
      canvasBus._emitApply(parsed);
      // Persist server-driven full replacements so a refresh keeps them.
      if (parsed.type === 'set') {
        try {
          const wrapped = {
            type: 'excalidraw',
            version: 2,
            source: 'tango-mcp',
            elements: parsed.elements,
            appState: sanitizeAppState(parsed.appState ?? {}),
            files: parsed.files ?? {},
          };
          sketchStore.setCurrent(JSON.stringify(wrapped));
        } catch {
          // ignore
        }
      }
    });

    return () => {
      offSnapshot();
      try {
        ws.close();
      } catch {
        // already closed
      }
      wsRef.current = null;
    };
  }, [generation]);

  return (
    <div className="h-full w-full bg-card">
      {load.status === 'ready' && (
        <DesignerCanvas
          key={generation}
          initialData={load.initialData}
          onPersist={onPersist}
          onReady={handleReady}
        />
      )}
    </div>
  );
}
