'use client';

// The shape draw tools, extracted from UIMockCanvas: armed-tool state, the
// crosshair overlay's pointer handlers, and the rubber band. Pointer down
// hit-tests the screen frames through screenRefs; drag coords convert
// client → frame-local by dividing by camera.zoom (getBoundingClientRect
// already includes the transform). One-shot: committing a draw disarms back
// to select. The pure drag→geometry math lives in src/lib/shapeDraw.ts.

import {
  type PointerEvent as ReactPointerEvent,
  type MutableRefObject,
  type RefObject,
  useCallback,
  useRef,
  useState,
} from 'react';
import { dropAtPoint, shapeFromDrag } from '@/lib/shapeDraw';
import { NODE_DEFAULTS, makeNode } from '@/lib/uiMockDefaults';
import type { UINode, UINodeType, UISpec } from '@/lib/uiMockProtocol';

export function useDrawTool({
  cameraZoom,
  screenRefs,
  specRef,
  gestureActiveRef,
  onCommit,
}: {
  cameraZoom: number;
  screenRefs: RefObject<Map<string, HTMLDivElement>>;
  specRef: RefObject<UISpec>;
  // Shared with the camera: suppress wheel-zoom / camera shortcuts mid-draw —
  // a camera move would invalidate the frame rect captured at pointer down.
  gestureActiveRef: MutableRefObject<boolean>;
  // Insert the drawn node and select it (the canvas owns spec + selection).
  onCommit: (screenId: string, node: UINode) => void;
}) {
  const [tool, setTool] = useState<UINodeType | null>(null);
  const toolRef = useRef(tool);
  toolRef.current = tool;
  // Live rubber-band rect, in draw-overlay (screen-space) coords.
  const [rubber, setRubber] = useState<{
    start: { x: number; y: number };
    cur: { x: number; y: number };
  } | null>(null);
  const drawSession = useRef<{
    screenId: string;
    // Client-space rect of the screen frame at gesture start.
    frameRect: { left: number; top: number };
    // Client-space rect of the overlay (rubber-band coordinate origin).
    overlayRect: { left: number; top: number };
    startClient: { x: number; y: number };
    shift: boolean;
  } | null>(null);

  const armTool = useCallback((type: UINodeType) => {
    setTool((prev) => (prev === type ? null : type));
  }, []);

  const cancelDraw = useCallback(() => {
    drawSession.current = null;
    gestureActiveRef.current = false;
    setRubber(null);
  }, [gestureActiveRef]);

  const disarm = useCallback(() => {
    setTool(null);
    cancelDraw();
  }, [cancelDraw]);

  const onDrawPointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      if (e.button !== 0 || !toolRef.current) return;
      // Hit-test the screen frames (client space — rects include the camera).
      let hit: { id: string; rect: DOMRect } | null = null;
      for (const [id, el] of screenRefs.current ?? []) {
        const rect = el.getBoundingClientRect();
        if (
          e.clientX >= rect.left &&
          e.clientX <= rect.right &&
          e.clientY >= rect.top &&
          e.clientY <= rect.bottom
        ) {
          hit = { id, rect };
          break;
        }
      }
      if (!hit) return;
      e.preventDefault();
      const overlayRect = e.currentTarget.getBoundingClientRect();
      try {
        e.currentTarget.setPointerCapture(e.pointerId);
      } catch {
        // pointer already gone — draw uncaptured
      }
      drawSession.current = {
        screenId: hit.id,
        frameRect: { left: hit.rect.left, top: hit.rect.top },
        overlayRect: { left: overlayRect.left, top: overlayRect.top },
        startClient: { x: e.clientX, y: e.clientY },
        shift: e.shiftKey,
      };
      gestureActiveRef.current = true;
      const start = {
        x: e.clientX - overlayRect.left,
        y: e.clientY - overlayRect.top,
      };
      setRubber({ start, cur: start });
    },
    [gestureActiveRef, screenRefs],
  );

  const onDrawPointerMove = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      const session = drawSession.current;
      if (!session) return;
      session.shift = e.shiftKey;
      setRubber((prev) =>
        prev
          ? {
              start: prev.start,
              cur: {
                x: e.clientX - session.overlayRect.left,
                y: e.clientY - session.overlayRect.top,
              },
            }
          : prev,
      );
    },
    [],
  );

  const onDrawPointerUp = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      const session = drawSession.current;
      const type = toolRef.current;
      cancelDraw();
      if (!session || !type) return;
      const screen = specRef.current.screens.find(
        (s) => s.id === session.screenId,
      );
      if (!screen) return;
      const toFrame = (clientX: number, clientY: number) => ({
        x: (clientX - session.frameRect.left) / cameraZoom,
        y: (clientY - session.frameRect.top) / cameraZoom,
      });
      const start = toFrame(session.startClient.x, session.startClient.y);
      const end = toFrame(e.clientX, e.clientY);
      const geom =
        shapeFromDrag(type, start, end, {
          shift: session.shift || e.shiftKey,
          frame: screen.frame,
        }) ??
        // Click (or sub-minimum drag): drop the default size at the point.
        dropAtPoint(NODE_DEFAULTS[type], start, screen.frame);
      const node = makeNode(type, geom.x, geom.y);
      node.width = geom.width;
      node.height = geom.height;
      if ('end' in geom && geom.end) {
        node.props = { ...node.props, end: geom.end };
      }
      onCommit(screen.id, node);
      setTool(null);
    },
    [cameraZoom, cancelDraw, onCommit, specRef],
  );

  return {
    tool,
    rubber,
    armTool,
    disarm,
    cancelDraw,
    onDrawPointerDown,
    onDrawPointerMove,
    onDrawPointerUp,
  };
}
