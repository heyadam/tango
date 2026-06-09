'use client';

import { useCallback, useContext, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import dynamic from 'next/dynamic';
import { RefreshCw, Send } from 'lucide-react';
import type { ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { Button } from '@/components/ui/button';
import { writeSnapshot } from '@/lib/designSnapshot';
import { sketchStore } from '@/lib/sketchStore';
import { canvasBus, sanitizeAppState, type ApplyMsg } from '@/lib/canvasBus';
import type { ScreenshotRequestMsg } from '@/lib/canvasProtocol';
import { PanelHeaderRightSlot } from '@/lib/leftPanelSlots';
import { terminalBus } from '@/lib/terminalBus';
import {
  TERMINAL_AGENTS,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { workspaceBus } from '@/lib/workspaceBus';
import { openWS } from '@/lib/wsClient';
import type { DesignerHandles } from './DesignerCanvas';

const DesignerCanvas = dynamic(() => import('./DesignerCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-background" />,
});

// Brand cream for Excalidraw's `viewBackgroundColor`. Excalidraw renders to
// <canvas>, so it can't read the `--background` CSS token directly — we mirror
// it as a hex literal here. Keep in sync with `--background` in globals.css
// (oklch(0.95 0.02 85) ≈ #F4EEDF). Forced on every load so Excalidraw's bg is
// a brand default rather than a per-canvas preference.
const SKETCH_BG_COLOR = '#F4EEDF';

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
  terminalAgent: TerminalAgentId;
};

export default function SketchPanel({ terminalAgent }: Props) {
  const handlesRef = useRef<DesignerHandles | null>(null);
  const terminalAgentMeta = TERMINAL_AGENTS[terminalAgent];
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });
  const [sendBusy, setSendBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
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
          appState: { viewBackgroundColor: SKETCH_BG_COLOR },
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
    // Force the brand cream bg on every load. Excalidraw persists
    // viewBackgroundColor via onChange, but we treat the canvas bg as a brand
    // default rather than a per-user preference — overwriting on each load
    // keeps it consistent across workspaces and refreshes.
    const seeded: ExcalidrawInitialDataState = parsed ?? { elements: [] };
    seeded.appState = {
      ...(seeded.appState ?? {}),
      viewBackgroundColor: SKETCH_BG_COLOR,
    };
    setLoad({ status: 'ready', initialData: seeded });
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

  const handleReady = useCallback((handles: DesignerHandles) => {
    handlesRef.current = handles;
  }, []);

  const sendToClaude = useCallback(async () => {
    if (sendBusy) return;
    const handles = handlesRef.current;
    if (!handles) return;
    setSendBusy(true);
    setStatus(null);
    try {
      const blob = await handles.getPng();
      const { relPath } = await writeSnapshot(blob);
      terminalBus.sendToTerminal(`# review design at ${relPath}\n`);
      setStatus(`Sent ${relPath} to ${terminalAgentMeta.shortLabel}.`);
    } catch (err) {
      setStatus(
        `Send failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      setSendBusy(false);
    }
  }, [sendBusy, terminalAgentMeta.shortLabel]);

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

  const rightSlot = useContext(PanelHeaderRightSlot);

  return (
    <div className="flex h-full min-h-0 w-full flex-col bg-card">
      {rightSlot
        ? createPortal(
            <Button
              size="sm"
              onClick={sendToClaude}
              disabled={sendBusy || load.status !== 'ready'}
            >
              {sendBusy ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <Send className="size-3.5" />
              )}
              {terminalAgentMeta.sendLabel}
            </Button>,
            rightSlot,
          )
        : null}

      <div className="min-h-0 flex-1">
        {load.status === 'ready' && (
          <DesignerCanvas
            key={generation}
            initialData={load.initialData}
            onPersist={onPersist}
            onReady={handleReady}
          />
        )}
      </div>

      {status && (
        <div className="shrink-0 border-t border-border bg-background px-4 py-2 font-mono text-[11px] text-muted-foreground">
          {status}
        </div>
      )}
    </div>
  );
}
