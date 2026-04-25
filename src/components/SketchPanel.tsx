'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import type { ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { sketchStore } from '@/lib/sketchStore';
import { canvasBus, sanitizeAppState, type ApplyMsg } from '@/lib/canvasBus';
import { writeSnapshot } from '@/lib/designSnapshot';
import { terminalBus } from '@/lib/terminalBus';
import type { DesignerHandles } from './DesignerCanvas';
import AgentTrigger from './AgentTrigger';

const DesignerCanvas = dynamic(() => import('./DesignerCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-neutral-950" />,
});

type LoadState =
  | { status: 'loading' }
  | { status: 'ready'; initialData: ExcalidrawInitialDataState | null };

type ScreenshotRequestMsg = {
  type: 'screenshot_request';
  requestId: string;
  opts?: { mime?: string; quality?: number; maxDim?: number };
};

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

export default function SketchPanel() {
  const handlesRef = useRef<DesignerHandles | null>(null);
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });
  const [busy, setBusy] = useState(false);
  const [lastPath, setLastPath] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

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

  const onReady = useCallback((handles: DesignerHandles) => {
    handlesRef.current = handles;
  }, []);

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
  }, []);

  const handleSend = useCallback(async () => {
    if (!handlesRef.current || busy) return;
    setBusy(true);
    setError(null);
    try {
      const blob = await handlesRef.current.getPng();
      const { relPath } = await writeSnapshot(blob);
      terminalBus.sendToTerminal(`# review design at ${relPath}\n`);
      setLastPath(relPath);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [busy]);

  return (
    <div className="flex h-full flex-col bg-neutral-900">
      <div className="flex shrink-0 items-center justify-between border-b border-neutral-800 px-4 py-2">
        <div className="flex items-baseline gap-3">
          <h1 className="text-sm font-medium text-neutral-200">Sketch</h1>
          {lastPath && !error && (
            <span className="font-mono text-[11px] text-neutral-500">
              sent {lastPath}
            </span>
          )}
          {error && (
            <span className="font-mono text-[11px] text-red-400">{error}</span>
          )}
        </div>
        <div className="flex items-center gap-3">
          <AgentTrigger />
          <button
            type="button"
            onClick={handleSend}
            disabled={busy || load.status !== 'ready'}
            className="rounded-md border border-neutral-700 bg-neutral-800 px-3 py-1.5 text-xs font-medium text-neutral-100 transition-colors hover:border-neutral-500 hover:bg-neutral-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {busy ? 'Sending…' : 'Send to Claude'}
          </button>
        </div>
      </div>
      <div className="min-h-0 flex-1">
        {load.status === 'ready' && (
          <DesignerCanvas
            initialData={load.initialData}
            onPersist={onPersist}
            onReady={onReady}
          />
        )}
      </div>
    </div>
  );
}
