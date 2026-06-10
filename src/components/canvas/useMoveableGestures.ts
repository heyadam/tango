'use client';

// react-moveable drag/resize handlers, extracted from UIMockCanvas. During a
// gesture we mutate the DOM directly for smoothness; on end we commit final
// geometry to the spec (origin + delta) and pin the wrapper's inline
// left/top/width/height to the same values before queuing the spec update.
// Pinning matters: React's reconciler skips writing same-value style props,
// so a naive "clear inline overrides; let React's render restore" sequence
// ends up clearing whatever onResize/onDrag set without React putting
// anything back — the wrapper briefly has no width/height and collapses to
// its content's intrinsic size. The origin is captured on *Start so a
// server-driven `set` arriving mid-gesture can't shift the base.

import {
  type MutableRefObject,
  type RefObject,
  useCallback,
  useRef,
} from 'react';
import type {
  OnDrag,
  OnDragEnd,
  OnDragGroup,
  OnDragGroupEnd,
  OnDragGroupStart,
  OnDragStart,
  OnResize,
  OnResizeEnd,
  OnResizeGroup,
  OnResizeGroupEnd,
  OnResizeGroupStart,
  OnResizeStart,
} from 'react-moveable';
import { findNodeInSpec } from '@/lib/uiMockOps';
import type { UINode, UISpec } from '@/lib/uiMockProtocol';

type Origin = { x: number; y: number; width: number; height: number };

// Restore the inline geometry of a target whose gesture didn't commit.
// React's prev-render tracked values match `origin`, so its diff would skip
// writing — we have to put the values back ourselves. Without an origin
// (gesture started outside our normal flow) we just clear the overrides and
// hope the next render touches the styles.
function restoreInlineGeometry(
  target: HTMLElement,
  origin: Origin | undefined,
): void {
  target.style.transform = '';
  if (origin) {
    target.style.width = `${origin.width}px`;
    target.style.height = `${origin.height}px`;
    target.style.left = `${origin.x}px`;
    target.style.top = `${origin.y}px`;
  } else {
    target.style.width = '';
    target.style.height = '';
  }
}

export function useMoveableGestures({
  specRef,
  gestureActiveRef,
  aiIslandRef,
  updateNode,
  updateNodes,
}: {
  specRef: RefObject<UISpec>;
  gestureActiveRef: MutableRefObject<boolean>;
  // The AI sparkle/popout island hides for the duration of a gesture —
  // imperatively, no setState mid-drag; the [spec]-keyed anchoring effect
  // re-positions on commit.
  aiIslandRef: RefObject<HTMLDivElement | null>;
  updateNode: (id: string, patch: Partial<UINode>) => void;
  updateNodes: (patches: Map<string, Partial<UINode>>) => void;
}) {
  // Origin geometry stashed at drag/resize start, keyed by node id. The end
  // handlers commit `origin + delta` rather than reading the live spec —
  // otherwise a server-driven `set` arriving mid-drag would shift the base
  // and the user's commit would land in a wildly wrong spot.
  const dragOrigin = useRef<Map<string, Origin>>(new Map());

  const stashOrigin = useCallback(
    (id: string) => {
      const node = findNodeInSpec(specRef.current, id);
      if (!node) return;
      dragOrigin.current.set(id, {
        x: node.x,
        y: node.y,
        width: node.width,
        height: node.height,
      });
    },
    [specRef],
  );

  const hideAiIsland = useCallback(() => {
    if (aiIslandRef.current) aiIslandRef.current.style.visibility = 'hidden';
  }, [aiIslandRef]);
  const showAiIsland = useCallback(() => {
    if (aiIslandRef.current) aiIslandRef.current.style.visibility = '';
  }, [aiIslandRef]);

  const onDragStart = useCallback(
    (e: OnDragStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      const id = (e.target as HTMLElement).getAttribute('data-mock-id');
      if (id) stashOrigin(id);
    },
    [stashOrigin, hideAiIsland, gestureActiveRef],
  );

  const onDrag = useCallback((e: OnDrag) => {
    e.target.style.transform = e.transform;
  }, []);

  const onDragEnd = useCallback(
    (e: OnDragEnd) => {
      gestureActiveRef.current = false;
      showAiIsland();
      const target = e.target as HTMLElement;
      const id = target.getAttribute('data-mock-id');
      if (!id) {
        target.style.transform = '';
        return;
      }
      const origin = dragOrigin.current.get(id);
      dragOrigin.current.delete(id);
      const last = e.isDrag
        ? (e.lastEvent?.beforeTranslate as [number, number] | undefined)
        : undefined;
      if (!last || !origin) {
        restoreInlineGeometry(target, origin);
        return;
      }
      const newX = origin.x + last[0];
      const newY = origin.y + last[1];
      target.style.transform = '';
      target.style.left = `${newX}px`;
      target.style.top = `${newY}px`;
      updateNode(id, { x: newX, y: newY });
    },
    [updateNode, showAiIsland, gestureActiveRef],
  );

  const onDragGroupStart = useCallback(
    (e: OnDragGroupStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      for (const ev of e.events) {
        const id = (ev.target as HTMLElement).getAttribute('data-mock-id');
        if (id) stashOrigin(id);
      }
    },
    [stashOrigin, hideAiIsland, gestureActiveRef],
  );

  const onDragGroup = useCallback((e: OnDragGroup) => {
    for (const ev of e.events) {
      ev.target.style.transform = ev.transform;
    }
  }, []);

  const onDragGroupEnd = useCallback(
    (e: OnDragGroupEnd) => {
      gestureActiveRef.current = false;
      showAiIsland();
      const patches = new Map<string, Partial<UINode>>();
      for (const ev of e.events) {
        const target = ev.target as HTMLElement;
        const id = target.getAttribute('data-mock-id');
        const origin = id ? dragOrigin.current.get(id) : undefined;
        if (id) dragOrigin.current.delete(id);
        const last = e.isDrag
          ? (ev.lastEvent?.beforeTranslate as [number, number] | undefined)
          : undefined;
        if (!id || !last || !origin) {
          restoreInlineGeometry(target, origin);
          continue;
        }
        const newX = origin.x + last[0];
        const newY = origin.y + last[1];
        target.style.transform = '';
        target.style.left = `${newX}px`;
        target.style.top = `${newY}px`;
        patches.set(id, { x: newX, y: newY });
      }
      updateNodes(patches);
    },
    [updateNodes, showAiIsland, gestureActiveRef],
  );

  const onResizeStart = useCallback(
    (e: OnResizeStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      const id = (e.target as HTMLElement).getAttribute('data-mock-id');
      if (id) stashOrigin(id);
    },
    [stashOrigin, hideAiIsland, gestureActiveRef],
  );

  const onResize = useCallback((e: OnResize) => {
    e.target.style.width = `${e.width}px`;
    e.target.style.height = `${e.height}px`;
    e.target.style.transform = e.drag.transform;
  }, []);

  const onResizeEnd = useCallback(
    (e: OnResizeEnd) => {
      gestureActiveRef.current = false;
      showAiIsland();
      const target = e.target as HTMLElement;
      const id = target.getAttribute('data-mock-id');
      if (!id) {
        target.style.transform = '';
        target.style.width = '';
        target.style.height = '';
        return;
      }
      const origin = dragOrigin.current.get(id);
      dragOrigin.current.delete(id);
      const last = e.lastEvent;
      const before = last?.drag?.beforeTranslate as
        | [number, number]
        | undefined;
      const w = last ? Number(last.width) : NaN;
      const h = last ? Number(last.height) : NaN;
      if (!origin || !before || !Number.isFinite(w) || !Number.isFinite(h)) {
        restoreInlineGeometry(target, origin);
        return;
      }
      const newW = Math.max(8, Math.round(w));
      const newH = Math.max(8, Math.round(h));
      const newX = origin.x + before[0];
      const newY = origin.y + before[1];
      target.style.transform = '';
      target.style.width = `${newW}px`;
      target.style.height = `${newH}px`;
      target.style.left = `${newX}px`;
      target.style.top = `${newY}px`;
      updateNode(id, { x: newX, y: newY, width: newW, height: newH });
    },
    [updateNode, showAiIsland, gestureActiveRef],
  );

  const onResizeGroupStart = useCallback(
    (e: OnResizeGroupStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      for (const ev of e.events) {
        const id = (ev.target as HTMLElement).getAttribute('data-mock-id');
        if (id) stashOrigin(id);
      }
    },
    [stashOrigin, hideAiIsland, gestureActiveRef],
  );

  const onResizeGroup = useCallback((e: OnResizeGroup) => {
    for (const ev of e.events) {
      ev.target.style.width = `${ev.width}px`;
      ev.target.style.height = `${ev.height}px`;
      ev.target.style.transform = ev.drag.transform;
    }
  }, []);

  const onResizeGroupEnd = useCallback(
    (e: OnResizeGroupEnd) => {
      gestureActiveRef.current = false;
      showAiIsland();
      const patches = new Map<string, Partial<UINode>>();
      for (const ev of e.events) {
        const target = ev.target as HTMLElement;
        const id = target.getAttribute('data-mock-id');
        const origin = id ? dragOrigin.current.get(id) : undefined;
        if (id) dragOrigin.current.delete(id);
        const last = ev.lastEvent;
        const before = last?.drag?.beforeTranslate as
          | [number, number]
          | undefined;
        const w = last ? Number(last.width) : NaN;
        const h = last ? Number(last.height) : NaN;
        if (
          !id ||
          !origin ||
          !before ||
          !Number.isFinite(w) ||
          !Number.isFinite(h)
        ) {
          restoreInlineGeometry(target, origin);
          continue;
        }
        const newW = Math.max(8, Math.round(w));
        const newH = Math.max(8, Math.round(h));
        const newX = origin.x + before[0];
        const newY = origin.y + before[1];
        target.style.transform = '';
        target.style.width = `${newW}px`;
        target.style.height = `${newH}px`;
        target.style.left = `${newX}px`;
        target.style.top = `${newY}px`;
        patches.set(id, { x: newX, y: newY, width: newW, height: newH });
      }
      updateNodes(patches);
    },
    [updateNodes, showAiIsland, gestureActiveRef],
  );

  return {
    onDragStart,
    onDrag,
    onDragEnd,
    onDragGroupStart,
    onDragGroup,
    onDragGroupEnd,
    onResizeStart,
    onResize,
    onResizeEnd,
    onResizeGroupStart,
    onResizeGroup,
    onResizeGroupEnd,
  };
}
