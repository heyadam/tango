'use client';

import { useEffect, useRef } from 'react';
import {
  CaptureUpdateAction,
  Excalidraw,
  exportToBlob,
  serializeAsJSON,
} from '@excalidraw/excalidraw';
import type {
  ExcalidrawImperativeAPI,
  ExcalidrawInitialDataState,
} from '@excalidraw/excalidraw/types';
import '@excalidraw/excalidraw/index.css';
import { canvasBus, sanitizeAppState } from '@/lib/canvasBus';

export type DesignerHandles = {
  getPng: () => Promise<Blob>;
  getSerialized: () => string;
  applyScene: (
    elements: unknown[],
    appState?: Record<string, unknown>,
    files?: Record<string, unknown>,
  ) => void;
  appendElements: (elements: unknown[]) => void;
};

type Props = {
  initialData?: ExcalidrawInitialDataState | null;
  onPersist?: (json: string) => void;
  onReady?: (handles: DesignerHandles) => void;
};

const PERSIST_DEBOUNCE_MS = 500;

export default function DesignerCanvas({ initialData, onPersist, onReady }: Props) {
  const persistTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const apiRef = useRef<ExcalidrawImperativeAPI | null>(null);

  useEffect(() => {
    return () => {
      if (persistTimer.current) clearTimeout(persistTimer.current);
    };
  }, []);

  // Subscribe to bus updates from the server. Always reach through apiRef at
  // call time — Excalidraw can remount and the captured api would go stale.
  useEffect(() => {
    return canvasBus._onApply((msg) => {
      const api = apiRef.current;
      if (!api) return;
      if (msg.type === 'set') {
        const cleanAppState = sanitizeAppState(msg.appState);
        api.updateScene({
          elements: msg.elements as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['elements'],
          appState: cleanAppState as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['appState'],
          captureUpdate: CaptureUpdateAction.IMMEDIATELY,
        });
      } else if (msg.type === 'patch' && msg.mode === 'append') {
        const current = api.getSceneElements();
        api.updateScene({
          elements: [...current, ...(msg.elements as typeof current)],
          captureUpdate: CaptureUpdateAction.IMMEDIATELY,
        });
      }
    });
  }, []);

  return (
    <div className="h-full w-full">
      <Excalidraw
        initialData={initialData ?? undefined}
        excalidrawAPI={(api: ExcalidrawImperativeAPI) => {
          apiRef.current = api;
          if (!onReady) return;
          onReady({
            getPng: async () => {
              const blob = await exportToBlob({
                elements: api.getSceneElements(),
                appState: api.getAppState(),
                files: api.getFiles(),
                mimeType: 'image/png',
              });
              if (!blob) throw new Error('exportToBlob returned null');
              return blob;
            },
            getSerialized: () =>
              serializeAsJSON(
                api.getSceneElements(),
                api.getAppState(),
                api.getFiles(),
                'local',
              ),
            applyScene: (elements, appState) => {
              const live = apiRef.current;
              if (!live) return;
              const cleanAppState = sanitizeAppState(appState);
              live.updateScene({
                elements: elements as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['elements'],
                appState: cleanAppState as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['appState'],
                captureUpdate: CaptureUpdateAction.IMMEDIATELY,
              });
            },
            appendElements: (elements) => {
              const live = apiRef.current;
              if (!live) return;
              const current = live.getSceneElements();
              live.updateScene({
                elements: [...current, ...(elements as typeof current)],
                captureUpdate: CaptureUpdateAction.IMMEDIATELY,
              });
            },
          });
        }}
        onChange={(elements, appState, files) => {
          if (persistTimer.current) clearTimeout(persistTimer.current);
          persistTimer.current = setTimeout(() => {
            // Forward to the server so MCP `get_canvas_state` sees user edits.
            // Sanitize appState — it contains a `collaborators` Map that
            // JSON.stringify would corrupt to {}.
            canvasBus._emitSnapshot({
              elements: elements as unknown as unknown[],
              appState: sanitizeAppState(
                appState as unknown as Record<string, unknown>,
              ),
              files: files as unknown as Record<string, unknown>,
            });
            if (onPersist) {
              onPersist(serializeAsJSON(elements, appState, files, 'local'));
            }
          }, PERSIST_DEBOUNCE_MS);
        }}
      />
    </div>
  );
}
