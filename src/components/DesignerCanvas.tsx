'use client';

import { useEffect, useMemo, useRef } from 'react';
import {
  CaptureUpdateAction,
  Excalidraw,
  exportToBlob,
  restoreElements,
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
  getImage: (opts?: {
    mime?: string;
    quality?: number;
    maxDim?: number;
  }) => Promise<{ mime: string; bytes: Uint8Array }>;
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
  // `restoreElements` fills in defaults for skeleton-shaped MCP payloads (e.g.
  // an arrow without `points`) — without it Excalidraw crashes during render
  // when iterating over scene elements.
  useEffect(() => {
    return canvasBus._onApply((msg) => {
      const api = apiRef.current;
      if (!api) return;
      if (msg.type === 'set') {
        const cleanAppState = sanitizeAppState(msg.appState);
        const restored = restoreElements(
          msg.elements as Parameters<typeof restoreElements>[0],
          null,
        );
        api.updateScene({
          elements: restored as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['elements'],
          appState: cleanAppState as Parameters<ExcalidrawImperativeAPI['updateScene']>[0]['appState'],
          captureUpdate: CaptureUpdateAction.IMMEDIATELY,
        });
      } else if (msg.type === 'patch' && msg.mode === 'append') {
        const current = api.getSceneElements();
        const restored = restoreElements(
          msg.elements as Parameters<typeof restoreElements>[0],
          null,
        );
        api.updateScene({
          elements: [...current, ...(restored as typeof current)],
          captureUpdate: CaptureUpdateAction.IMMEDIATELY,
        });
      }
    });
  }, []);

  // Normalize initialData on mount so a localStorage cache poisoned by a prior
  // skeleton-shaped MCP write doesn't crash Excalidraw on rehydrate. Idempotent
  // on already-well-formed elements.
  const normalizedInitialData = useMemo<ExcalidrawInitialDataState | undefined>(() => {
    if (!initialData) return undefined;
    return {
      ...initialData,
      elements: restoreElements(
        (initialData.elements ?? []) as Parameters<typeof restoreElements>[0],
        null,
      ) as ExcalidrawInitialDataState['elements'],
      appState: sanitizeAppState(
        initialData.appState as unknown as Record<string, unknown>,
      ) as ExcalidrawInitialDataState['appState'],
    };
  }, [initialData]);

  return (
    <div className="h-full w-full">
      <Excalidraw
        initialData={normalizedInitialData}
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
            getImage: async (opts) => {
              const mime = opts?.mime ?? 'image/jpeg';
              const blob = await exportToBlob({
                elements: api.getSceneElements(),
                appState: api.getAppState(),
                files: api.getFiles(),
                mimeType: mime,
                quality: opts?.quality ?? 0.6,
                maxWidthOrHeight: opts?.maxDim ?? 768,
              });
              if (!blob) throw new Error('exportToBlob returned null');
              const bytes = new Uint8Array(await blob.arrayBuffer());
              return { mime, bytes };
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
