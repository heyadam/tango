'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import type { ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { sketchStore } from '@/lib/sketchStore';
import { canvasBus, sanitizeAppState, type ApplyMsg } from '@/lib/canvasBus';
import type { DesignerHandles } from './DesignerCanvas';

const DesignerCanvas = dynamic(() => import('./DesignerCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-neutral-950" />,
});

type LoadState =
  | { status: 'loading' }
  | { status: 'ready'; initialData: ExcalidrawInitialDataState | null };

type Props = {
  onCanvasReady?: (handles: DesignerHandles) => void;
};

export default function SketchPanel({ onCanvasReady }: Props) {
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });

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
  }, []);

  const wsRef = useRef<WebSocket | null>(null);

  const onPersist = useCallback((json: string) => {
    sketchStore.setCurrent(json);
  }, []);

  // Open the canvas WS bridge. Locally-debounced snapshots from the canvas
  // (forwarded via canvasBus) ship up to the server cache; server frames apply
  // back into Excalidraw via canvasBus._emitApply, which DesignerCanvas owns.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${window.location.host}/ws/canvas`);
    wsRef.current = ws;

    const offSnapshot = canvasBus._onSnapshot((snap) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: 'snapshot', ...snap }));
      } catch {
        // socket dying
      }
    });

    ws.addEventListener('message', (ev) => {
      let parsed: ApplyMsg;
      try {
        parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : '') as ApplyMsg;
      } catch {
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
  }, []);

  return (
    <div className="h-full w-full bg-neutral-900">
      {load.status === 'ready' && (
        <DesignerCanvas
          initialData={load.initialData}
          onPersist={onPersist}
          onReady={onCanvasReady}
        />
      )}
    </div>
  );
}
