'use client';

// Camera (pan/zoom) state and interactions for the design canvas, extracted
// from UIMockCanvas. View-only: the content layer renders under
// translate+scale; the camera never enters the spec or the wire.
//
// Owns: the camera value, the viewport/content element refs it measures, the
// gesture/pointer-over/user-moved flags, space-held pan mode, wheel zoom/pan,
// camera keyboard shortcuts, and auto-fit on content appearing. The caller
// wires the returned refs/handlers into its DOM and reacts to `camera`.

import {
  type PointerEvent as ReactPointerEvent,
  type RefObject,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import {
  type Camera,
  clampZoom,
  fitCamera,
  normalizeWheelDelta,
  panBy,
  wheelZoomFactor,
  zoomAtPoint,
} from '@/lib/uiCanvasCamera';
import type { UISpec } from '@/lib/uiMockProtocol';

// Shared guard for window-level key listeners: don't hijack keys headed for
// a text edit or a focused control (space activates a focused button).
export function isTypingTarget(t: EventTarget | null): boolean {
  const el = t as HTMLElement | null;
  return Boolean(
    el &&
      (el.isContentEditable ||
        el.tagName === 'INPUT' ||
        el.tagName === 'TEXTAREA' ||
        el.tagName === 'SELECT' ||
        el.tagName === 'BUTTON'),
  );
}

export function useCanvasCamera({
  editingId,
  screenCount,
  specRef,
  onBackgroundClick,
}: {
  editingId: string | null;
  screenCount: number;
  specRef: RefObject<UISpec>;
  // Clicks landing on the viewport background (not on content or a node).
  onBackgroundClick: () => void;
}) {
  const [camera, setCamera] = useState<Camera>({ x: 0, y: 0, zoom: 1 });
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  // True while a Moveable drag/resize (or a shape draw) is in flight — a
  // camera move mid-gesture would invalidate geometry captured at start.
  const gestureActiveRef = useRef(false);
  // Camera keyboard shortcuts only apply while the cursor is over the canvas
  // (the listeners live on window to beat the browser's own Cmd+/− zoom).
  const pointerOverRef = useRef(false);
  // Flips on the first user camera move; auto-fit (mount, screens streaming
  // in from an import) backs off once the user has taken the wheel.
  const userMovedCameraRef = useRef(false);
  // Space-held mounts the pan-capture overlay; grabbing tracks an active pan
  // drag (space or middle-mouse) for the cursor.
  const [spaceHeld, setSpaceHeld] = useState(false);
  const [grabbing, setGrabbing] = useState(false);
  const panLast = useRef<{ x: number; y: number } | null>(null);

  // Zoom anchored at the viewport center (keyboard / toolbar zoom).
  const zoomTo = useCallback((nextZoom: number) => {
    const vp = viewportRef.current;
    if (!vp) return;
    const point = { x: vp.clientWidth / 2, y: vp.clientHeight / 2 };
    userMovedCameraRef.current = true;
    setCamera((c) => zoomAtPoint(c, point, clampZoom(nextZoom)));
  }, []);

  const zoomStep = useCallback((factor: number) => {
    const vp = viewportRef.current;
    if (!vp) return;
    const point = { x: vp.clientWidth / 2, y: vp.clientHeight / 2 };
    userMovedCameraRef.current = true;
    setCamera((c) => zoomAtPoint(c, point, clampZoom(c.zoom * factor)));
  }, []);

  const fitToContent = useCallback(() => {
    const vp = viewportRef.current;
    const content = contentRef.current;
    if (!vp || !content) return;
    setCamera(
      fitCamera(
        { w: content.offsetWidth, h: content.offsetHeight },
        { w: vp.clientWidth, h: vp.clientHeight },
      ),
    );
  }, []);

  // Pan drags capture on the *viewport* (not the element under the pointer)
  // so the drag survives the space overlay unmounting mid-gesture. Capture is
  // best-effort: without it the pan still works while the pointer stays over
  // the canvas (move/up events bubble to the viewport's handlers).
  const beginPan = useCallback((e: ReactPointerEvent<HTMLDivElement>) => {
    try {
      viewportRef.current?.setPointerCapture(e.pointerId);
    } catch {
      // pointer already gone — pan uncaptured
    }
    panLast.current = { x: e.clientX, y: e.clientY };
    setGrabbing(true);
  }, []);

  const movePan = useCallback((e: ReactPointerEvent<HTMLDivElement>) => {
    const last = panLast.current;
    if (!last) return;
    const dx = e.clientX - last.x;
    const dy = e.clientY - last.y;
    if (dx === 0 && dy === 0) return;
    panLast.current = { x: e.clientX, y: e.clientY };
    userMovedCameraRef.current = true;
    setCamera((c) => panBy(c, dx, dy));
  }, []);

  const endPan = useCallback((e: ReactPointerEvent<HTMLDivElement>) => {
    if (!panLast.current) return;
    panLast.current = null;
    setGrabbing(false);
    try {
      viewportRef.current?.releasePointerCapture(e.pointerId);
    } catch {
      // capture already released
    }
  }, []);

  const onViewportPointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      if (e.button === 1) {
        // Middle-mouse pan; preventDefault suppresses platform autoscroll.
        e.preventDefault();
        beginPan(e);
        return;
      }
      if (e.button === 0 && e.target === e.currentTarget) {
        onBackgroundClick();
      }
    },
    [beginPan, onBackgroundClick],
  );

  // Wheel: pinch (ctrlKey in Chromium/Firefox) or Cmd+wheel zooms toward the
  // cursor; plain wheel pans. Native listener — React's root-level wheel
  // handlers are passive, so preventDefault (needed to beat browser page
  // zoom and back-swipe) wouldn't work through onWheel.
  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      if (gestureActiveRef.current) return;
      if (specRef.current.screens.length === 0) return;
      const { dx, dy } = normalizeWheelDelta(e.deltaX, e.deltaY, e.deltaMode);
      userMovedCameraRef.current = true;
      if (e.ctrlKey || e.metaKey) {
        const rect = el.getBoundingClientRect();
        const point = { x: e.clientX - rect.left, y: e.clientY - rect.top };
        setCamera((c) =>
          zoomAtPoint(c, point, clampZoom(c.zoom * wheelZoomFactor(dy))),
        );
      } else if (e.shiftKey && dx === 0) {
        // Shift+wheel on a mouse: vertical notches pan horizontally.
        setCamera((c) => panBy(c, -dy, 0));
      } else {
        setCamera((c) => panBy(c, -dx, -dy));
      }
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [specRef]);

  // Space-held pan mode. Cleared on keyup and window blur (Cmd+Tab while
  // holding space would otherwise leave the overlay stuck on).
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.code !== 'Space' || e.repeat) return;
      if (editingId) return;
      if (isTypingTarget(e.target)) return;
      if (!pointerOverRef.current) return;
      e.preventDefault();
      setSpaceHeld(true);
    };
    const onKeyUp = (e: KeyboardEvent) => {
      if (e.code === 'Space') setSpaceHeld(false);
    };
    const onBlur = () => setSpaceHeld(false);
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('blur', onBlur);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('blur', onBlur);
    };
  }, [editingId]);

  // Camera shortcuts: Cmd/Ctrl +/−/0, Shift+1 = fit. preventDefault beats the
  // browser's page zoom — which is why these are scoped to cursor-over-canvas.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (editingId || isTypingTarget(e.target)) return;
      if (!pointerOverRef.current || gestureActiveRef.current) return;
      if (specRef.current.screens.length === 0) return;
      const mod = e.metaKey || e.ctrlKey;
      if (mod && (e.key === '=' || e.key === '+')) {
        e.preventDefault();
        zoomStep(1.25);
      } else if (mod && e.key === '-') {
        e.preventDefault();
        zoomStep(1 / 1.25);
      } else if (mod && e.key === '0') {
        e.preventDefault();
        zoomTo(1);
      } else if (e.shiftKey && e.code === 'Digit1') {
        e.preventDefault();
        fitToContent();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [editingId, zoomStep, zoomTo, fitToContent, specRef]);

  // Zoom-to-fit when content appears (mount with a spec, Clear → re-import),
  // and as screens stream in from an import — until the user moves the
  // camera. Keyed on screen count, not the spec, so node edits never refit.
  // Layout effect: the content layer mounts in this same render and must be
  // measured before paint.
  useLayoutEffect(() => {
    if (screenCount === 0) {
      // Content went away — reset so the next content auto-fits again.
      userMovedCameraRef.current = false;
      setCamera({ x: 0, y: 0, zoom: 1 });
      return;
    }
    if (userMovedCameraRef.current) return;
    fitToContent();
  }, [screenCount, fitToContent]);

  return {
    camera,
    viewportRef,
    contentRef,
    gestureActiveRef,
    pointerOverRef,
    spaceHeld,
    grabbing,
    zoomTo,
    zoomStep,
    fitToContent,
    beginPan,
    movePan,
    endPan,
    onViewportPointerDown,
  };
}
