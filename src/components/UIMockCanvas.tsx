'use client';

// The core UI-mock renderer. Owns spec state, selection, drag/resize via
// react-moveable, text editing, and the snapshot-back-to-server flow. Sits
// behind a dynamic-import boundary in UIPanel because react-moveable touches
// `window` at module load.
//
// Coord model: every node sits at absolute pixel coords inside a per-screen
// frame. Frames are tiled left-to-right with a fixed gutter inside a content
// layer that pans/zooms under a camera transform (translate + scale, origin
// top-left — see uiCanvasCamera). Moveable stays a *sibling* of the content
// layer, so its container is untransformed and the camera scale sits between
// container and target: Moveable inverse-transforms drags through that
// matrix, so beforeTranslate / width / height arrive in frame coords and the
// drag-end → spec write stays 1:1. (Don't pass rootContainer / zoom to
// Moveable — those are for a control box *inside* the scaled subtree.)
// The camera is view state only: never serialized, never on the wire.
// Pinch-zoom arrives as ctrlKey+wheel (Chromium/Firefox); Safari's
// gesturechange events are not handled yet.
//
// Loop avoidance: server-driven `apply` updates lift `spec` into a fresh
// reference; the snapshot effect debounces and emits *the same* shape back
// up the WS. The bridge updates its cache without re-broadcasting (snapshots
// are not broadcast — see uiMockBridge), so there's no infinite ping-pong.

import {
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import Moveable from 'react-moveable';
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
import { Check, Layers, Maximize, Minus, Plus, Sparkles } from 'lucide-react';
import UIMockNode from './UIMockNode';
import UIAddPalette from './UIAddPalette';
import UIAIPopout from './UIAIPopout';
import UILayersPanel from './UILayersPanel';
import { Button } from './ui/button';
import { uiMockBus } from '@/lib/uiMockBus';
import type { ApplyMsg } from '@/lib/uiMockBus';
import {
  addNodesToScreen,
  removeNodesFromSpec,
  removeScreenFromSpec,
  reorderNodeInSpec,
  type ReorderOp,
} from '@/lib/uiMockOps';
import { screenFileNames } from '@/lib/specToSwiftUI';
import type { AgentTask } from '@/lib/terminalBus';
import { NODE_DEFAULTS, makeNode } from '@/lib/uiMockDefaults';
import {
  MAX_ZOOM,
  MIN_ZOOM,
  type Camera,
  clampZoom,
  fitCamera,
  normalizeWheelDelta,
  panBy,
  wheelZoomFactor,
  zoomAtPoint,
} from '@/lib/uiCanvasCamera';
import {
  EMPTY_SPEC,
  type UINode,
  type UINodeType,
  type UISpec,
} from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

const SNAPSHOT_DEBOUNCE_MS = 250;

// AI sparkle/card geometry for the clamp/flip math — all in untransformed
// wrapper coords (the floating layer is screen-space, constant size at any
// zoom). The card height is an estimate; only the flip heuristic uses it.
const AI_SPARKLE_PX = 28;
const AI_CARD_W = 288;
const AI_CARD_H = 220;
const AI_MARGIN = 8;

type Props = {
  initialSpec: UISpec;
  onPersist: (spec: UISpec) => void;
  // Fired when the user's working screen changes (selecting a node in another
  // screen, or clicking a frame's background). UIPanel ships it to the server
  // so the preview-host app shows the screen the user is actually editing.
  onActiveScreen?: (screenId: string) => void;
};

export default function UIMockCanvas({
  initialSpec,
  onPersist,
  onActiveScreen,
}: Props) {
  const [spec, setSpec] = useState<UISpec>(initialSpec ?? EMPTY_SPEC);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [editingId, setEditingId] = useState<string | null>(null);
  // Floating overlay visibility — the Add palette and Layers panel.
  const [addOpen, setAddOpen] = useState(false);
  const [layersOpen, setLayersOpen] = useState(false);
  // The user's working screen, lifted to state for display (title-row tint,
  // layers-panel highlight, screen-scope sparkle anchor). The wire report
  // stays deduped through lastActiveScreen below.
  const [activeScreenId, setActiveScreenId] = useState<string | null>(null);
  // The AI popout (sparkle → card) and its screen-space anchor positions.
  const [popout, setPopout] = useState<{ scope: AgentTask['scope'] } | null>(
    null,
  );
  const [aiPos, setAiPos] = useState<{
    sparkle: { left: number; top: number } | null;
    card: { left: number; top: number } | null;
  }>({ sparkle: null, card: null });
  // Bumped (debounced) when the wrapper resizes — sidebar expand/collapse,
  // window resize — so the clamp/flip math above re-runs against fresh bounds.
  const [wrapperEpoch, setWrapperEpoch] = useState(0);

  // Map<nodeId, wrapper-element> populated by callback refs on each rendered
  // node so we can hand react-moveable real DOM targets without re-querying.
  const nodeRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  // Map<screenId, frame-element> — same pattern, for the screen-scope sparkle
  // anchor (never querySelector).
  const screenRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const moveableRef = useRef<Moveable | null>(null);
  // The relative root div — the coordinate space of the floating layer.
  const wrapperRef = useRef<HTMLDivElement | null>(null);
  // The sparkle/popout island, hidden imperatively during gestures (no
  // setState mid-drag — the [spec]-keyed anchoring effect re-positions on
  // commit).
  const aiIslandRef = useRef<HTMLDivElement | null>(null);

  // Latest spec snapshot for callbacks closing over stale refs (e.g. drag-end
  // handlers that fire long after they were attached).
  const specRef = useRef(spec);
  specRef.current = spec;

  // Same pattern for selection, so the popout openers stay dep-free.
  const selectedIdsRef = useRef(selectedIds);
  selectedIdsRef.current = selectedIds;

  // Origin geometry stashed at drag/resize start, keyed by node id. The end
  // handlers commit `origin + delta` rather than reading the live spec —
  // otherwise a server-driven `set` arriving mid-drag would shift the base
  // and the user's commit would land in a wildly wrong spot.
  const dragOrigin = useRef<
    Map<string, { x: number; y: number; width: number; height: number }>
  >(new Map());

  const stashOrigin = useCallback((id: string) => {
    const node = findNode(specRef.current, id);
    if (!node) return;
    dragOrigin.current.set(id, {
      x: node.x,
      y: node.y,
      width: node.width,
      height: node.height,
    });
  }, []);

  // Tracks whether the next spec render came from a server-driven apply.
  // We bump this when an apply lands and skip one snapshot effect run — the
  // server cache is already in this state, no need to bounce it back. The
  // bridge wouldn't re-broadcast the snapshot, but skipping the round-trip
  // keeps the wire quiet.
  const skipNextSnapshot = useRef(false);

  // ── Server → browser apply ─────────────────────────────────────────────
  useEffect(() => {
    return uiMockBus._onApply((msg: ApplyMsg) => {
      if (msg.type === 'set') {
        skipNextSnapshot.current = true;
        setSpec(msg.spec);
        // Drop selection that no longer exists in the new spec.
        setSelectedIds((prev) => {
          const allIds = new Set(
            msg.spec.screens.flatMap((s) => s.nodes.map((n) => n.id)),
          );
          const next = prev.filter((id) => allIds.has(id));
          return next.length === prev.length ? prev : next;
        });
        setEditingId(null);
      } else if (msg.type === 'append_screen') {
        skipNextSnapshot.current = true;
        setSpec((prev) => ({
          ...prev,
          screens: [...prev.screens, msg.screen],
        }));
      }
    });
  }, []);

  // ── Browser → server snapshot (debounced) ──────────────────────────────
  // We skip:
  //   - the very first commit (initial spec / hydration from localStorage)
  //   - any commit triggered by a server-driven apply (skipNextSnapshot)
  // Everything else (drag/resize/text edit/delete) fires a debounced emit.
  const isFirstCommit = useRef(true);
  useEffect(() => {
    if (isFirstCommit.current) {
      isFirstCommit.current = false;
      return;
    }
    if (skipNextSnapshot.current) {
      skipNextSnapshot.current = false;
      // Persist locally so a refresh keeps server-driven content; just don't
      // ship the snapshot back up.
      onPersist(spec);
      return;
    }
    const timer = window.setTimeout(() => {
      uiMockBus._emitSnapshot(spec);
      onPersist(spec);
    }, SNAPSHOT_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [spec, onPersist]);

  // ── Selection helpers ─────────────────────────────────────────────────
  // Report the screen owning a node as the user's working screen (deduped).
  const lastActiveScreen = useRef<string | null>(null);
  const reportActiveScreen = useCallback(
    (screenId: string) => {
      // Display state updates unconditionally (React bails out on identical
      // values); the ref gates only the upstream wire report — otherwise the
      // [spec]-keyed default effect below desyncs the two on screen removal.
      setActiveScreenId(screenId);
      if (screenId === lastActiveScreen.current) return;
      lastActiveScreen.current = screenId;
      onActiveScreen?.(screenId);
    },
    [onActiveScreen],
  );

  // Display default for activeScreenId (mirrors the server's
  // reconcileActiveScreen): first screen when unset or pruned, null when
  // empty. Never reports upstream; the dedupe ref is cleared when its screen
  // vanished so a later re-add with the same id can fire the wire report.
  useEffect(() => {
    if (
      lastActiveScreen.current &&
      !spec.screens.some((s) => s.id === lastActiveScreen.current)
    ) {
      lastActiveScreen.current = null;
    }
    setActiveScreenId((prev) => {
      if (spec.screens.length === 0) return null;
      if (prev && spec.screens.some((s) => s.id === prev)) return prev;
      return spec.screens[0].id;
    });
  }, [spec]);
  const reportActiveScreenOfNode = useCallback(
    (nodeId: string) => {
      const screen = specRef.current.screens.find((s) =>
        s.nodes.some((n) => n.id === nodeId),
      );
      if (screen) reportActiveScreen(screen.id);
    },
    [reportActiveScreen],
  );

  const selectOnly = useCallback(
    (id: string) => {
      setSelectedIds([id]);
      setEditingId(null);
      reportActiveScreenOfNode(id);
    },
    [reportActiveScreenOfNode],
  );

  const addToSelection = useCallback(
    (id: string) => {
      setSelectedIds((prev) => (prev.includes(id) ? prev : [...prev, id]));
      setEditingId(null);
      reportActiveScreenOfNode(id);
    },
    [reportActiveScreenOfNode],
  );

  const clearSelection = useCallback(() => {
    setSelectedIds([]);
    setEditingId(null);
  }, []);

  const startEditing = useCallback((id: string) => {
    setSelectedIds([id]);
    setEditingId(id);
  }, []);

  const stopEditing = useCallback(() => {
    setEditingId(null);
  }, []);

  // ── Spec mutators ─────────────────────────────────────────────────────
  // Each one returns a new spec reference so React schedules a render, and
  // the snapshot effect picks it up.
  const updateNode = useCallback(
    (id: string, patch: Partial<UINode>) => {
      setSpec((prev) => ({
        ...prev,
        screens: prev.screens.map((screen) => ({
          ...screen,
          nodes: screen.nodes.map((node) =>
            node.id === id ? { ...node, ...patch } : node,
          ),
        })),
      }));
    },
    [],
  );

  // Stable (id, text) commit channel so NodeWrapper props don't change
  // identity every render — load-bearing for the React.memo on NodeWrapper.
  const commitNodeText = useCallback(
    (id: string, text: string) => {
      updateNode(id, { text });
    },
    [updateNode],
  );

  const updateNodes = useCallback(
    (patches: Map<string, Partial<UINode>>) => {
      if (patches.size === 0) return;
      setSpec((prev) => ({
        ...prev,
        screens: prev.screens.map((screen) => ({
          ...screen,
          nodes: screen.nodes.map((node) => {
            const patch = patches.get(node.id);
            return patch ? { ...node, ...patch } : node;
          }),
        })),
      }));
    },
    [],
  );

  const deleteSelected = useCallback(() => {
    if (selectedIds.length === 0) return;
    const toDrop = new Set(selectedIds);
    setSpec((prev) => ({
      ...prev,
      screens: prev.screens.map((screen) => ({
        ...screen,
        nodes: screen.nodes.filter((node) => !toDrop.has(node.id)),
      })),
    }));
    clearSelection();
  }, [selectedIds, clearSelection]);

  // ── Add / reorder / remove (Add palette + Layers panel) ────────────────
  // These reuse the shared pure ops in uiMockOps and flow through the normal
  // snapshot effect, so server-side Claude and the human edit the same way.
  const addNodeOfType = useCallback(
    (type: UINodeType) => {
      const current = specRef.current;
      if (current.screens.length === 0) return;
      // Drop onto the screen that owns the current selection, else the first.
      const target =
        current.screens.find((s) =>
          s.nodes.some((n) => selectedIds.includes(n.id)),
        ) ?? current.screens[0];
      const def = NODE_DEFAULTS[type];
      // Stagger so repeated adds don't stack exactly; clamp inside the frame.
      const stagger = (target.nodes.length % 6) * 24;
      const x = Math.max(0, Math.min(24 + stagger, target.frame.w - def.width));
      const y = Math.max(0, Math.min(24 + stagger, target.frame.h - def.height));
      const node = makeNode(type, x, y);
      try {
        setSpec(addNodesToScreen(current, target.id, [node]));
        setSelectedIds([node.id]);
        setEditingId(null);
      } catch {
        // id collision is effectively impossible with a random uuid; ignore.
      }
    },
    [selectedIds],
  );

  const reorderNode = useCallback((id: string, op: ReorderOp) => {
    try {
      setSpec(reorderNodeInSpec(specRef.current, id, op));
    } catch {
      // node vanished between render and click (server-driven set) — ignore.
    }
  }, []);

  const removeNode = useCallback((id: string) => {
    try {
      setSpec(removeNodesFromSpec(specRef.current, [id]));
      setSelectedIds((prev) => prev.filter((s) => s !== id));
    } catch {
      // already gone — ignore.
    }
  }, []);

  const handleLayerSelect = useCallback(
    (id: string, additive: boolean) => {
      if (additive) addToSelection(id);
      else selectOnly(id);
    },
    [addToSelection, selectOnly],
  );

  // ── AI popout (sparkle → card) ────────────────────────────────────────
  // All useCallback-stable: they're passed to UILayersPanel and read live
  // state through refs, so opening the popout never churns NodeWrapper props.
  const closePopout = useCallback(() => setPopout(null), []);

  const openPopoutForSelection = useCallback(() => {
    const ids = selectedIdsRef.current;
    if (ids.length === 0) return;
    const screen = specRef.current.screens.find((s) =>
      s.nodes.some((n) => n.id === ids[0]),
    );
    if (!screen) return;
    // A shift-click selection can span screens; scope only the nodes that
    // live on the resolved screen so the label and prompt never lie.
    const onScreen = ids.filter((id) =>
      screen.nodes.some((n) => n.id === id),
    );
    setPopout({
      scope: {
        kind: 'nodes',
        screenId: screen.id,
        screenTitle: screen.title,
        nodeIds: onScreen,
      },
    });
  }, []);

  const openPopoutForScreen = useCallback(
    (screenId: string) => {
      const screen = specRef.current.screens.find((s) => s.id === screenId);
      if (!screen) return;
      clearSelection();
      reportActiveScreen(screenId);
      setPopout({
        scope: { kind: 'screen', screenId, screenTitle: screen.title },
      });
    },
    [clearSelection, reportActiveScreen],
  );

  const selectScreen = useCallback(
    (screenId: string) => {
      clearSelection();
      reportActiveScreen(screenId);
    },
    [clearSelection, reportActiveScreen],
  );

  const removeScreen = useCallback((screenId: string) => {
    try {
      const next = removeScreenFromSpec(specRef.current, screenId);
      setSpec(next);
      setSelectedIds((prev) =>
        prev.filter((id) =>
          next.screens.some((s) => s.nodes.some((n) => n.id === id)),
        ),
      );
    } catch {
      // already gone — ignore.
    }
  }, []);

  // Close the popout when a server-driven spec change prunes its anchor
  // (e.g. the agent replaced the spec mid-prompt).
  useEffect(() => {
    if (!popout) return;
    const { scope } = popout;
    const anchorGone =
      scope.kind === 'screen'
        ? !spec.screens.some((s) => s.id === scope.screenId)
        : !(scope.nodeIds ?? []).some((id) =>
            spec.screens.some((s) => s.nodes.some((n) => n.id === id)),
          );
    if (anchorGone) setPopout(null);
  }, [spec, popout]);

  // ── Keyboard ──────────────────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Don't steal Backspace/Delete while the user is editing text.
      if (editingId) return;
      const target = e.target as HTMLElement | null;
      if (target && (target.isContentEditable || target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) {
        return;
      }
      // Escape closes the popout first, the selection second. (With focus in
      // the popout's textarea the typing-target guard above returns early and
      // the popout's own onKeyDown handles it.)
      if (e.key === 'Escape' && popout) {
        setPopout(null);
        return;
      }
      if (e.key === 'Backspace' || e.key === 'Delete') {
        if (selectedIds.length > 0) {
          e.preventDefault();
          deleteSelected();
        }
      } else if (e.key === 'Escape') {
        clearSelection();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [editingId, selectedIds.length, deleteSelected, clearSelection, popout]);

  // ── Camera (pan / zoom) ───────────────────────────────────────────────
  // View-only: the content layer renders under translate+scale. Never enters
  // the spec or the wire — see the header comment.
  const [camera, setCamera] = useState<Camera>({ x: 0, y: 0, zoom: 1 });
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  // True while a Moveable drag/resize is in flight — a camera move mid-gesture
  // would invalidate the matrix Moveable snapshotted at gesture start.
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
      // Clicks landing on the viewport background (not on the content layer
      // or a node) clear selection and exit text edit mode.
      if (e.button === 0 && e.target === e.currentTarget) {
        clearSelection();
      }
    },
    [beginPan, clearSelection],
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
  }, []);

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
  }, [editingId, zoomStep, zoomTo, fitToContent]);

  // Zoom-to-fit when content appears (mount with a spec, Clear → re-import),
  // and as screens stream in from an import — until the user moves the
  // camera. Keyed on screen count, not the spec, so node edits never refit.
  // Layout effect: the content layer mounts in this same render and must be
  // measured before paint.
  const screenCount = spec.screens.length;
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

  // Moveable doesn't watch ancestor transforms (its observers only cover the
  // target's own size/style) — re-read rects so the selection overlay tracks
  // the camera.
  useLayoutEffect(() => {
    moveableRef.current?.updateRect();
  }, [camera]);

  // Re-anchor when the wrapper itself resizes (debounced, mirroring the
  // Terminal fit observer's cadence).
  useEffect(() => {
    const el = wrapperRef.current;
    if (!el) return;
    let timer: number | null = null;
    const ro = new ResizeObserver(() => {
      if (timer !== null) window.clearTimeout(timer);
      timer = window.setTimeout(() => setWrapperEpoch((e) => e + 1), 50);
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
      if (timer !== null) window.clearTimeout(timer);
    };
  }, []);

  // ── AI island anchoring ───────────────────────────────────────────────
  // Wrapper-relative rects via getBoundingClientRect, so the sparkle/card
  // track the camera at constant size. Anchor: the popout's own scope while
  // open; otherwise the selection's union bbox, else the active screen.
  // Sparkle sits at the anchor's top-right (+8px up/right); the card opens at
  // the sparkle and flips left/above when it would clip the wrapper.
  useLayoutEffect(() => {
    const wrapper = wrapperRef.current;
    if (!wrapper) return;
    const wrapperRect = wrapper.getBoundingClientRect();

    type Rect = { top: number; right: number };
    const unionRect = (ids: string[]): Rect | null => {
      let top = Infinity;
      let right = -Infinity;
      let found = false;
      for (const id of ids) {
        const el = nodeRefs.current.get(id);
        if (!el) continue;
        const r = el.getBoundingClientRect();
        top = Math.min(top, r.top);
        right = Math.max(right, r.right);
        found = true;
      }
      return found ? { top, right } : null;
    };
    const screenRect = (id: string): Rect | null => {
      const el = screenRefs.current.get(id);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { top: r.top, right: r.right };
    };

    let anchor: Rect | null = null;
    if (popout) {
      anchor =
        popout.scope.kind === 'nodes'
          ? unionRect(popout.scope.nodeIds ?? [])
          : screenRect(popout.scope.screenId);
    } else if (selectedIds.length > 0) {
      anchor = unionRect(selectedIds);
    } else if (activeScreenId) {
      anchor = screenRect(activeScreenId);
    }
    if (!anchor) {
      setAiPos({ sparkle: null, card: null });
      return;
    }

    const clamp = (v: number, lo: number, hi: number) =>
      Math.min(Math.max(v, lo), Math.max(lo, hi));
    const right = anchor.right - wrapperRect.left;
    const top = anchor.top - wrapperRect.top;
    const sparkle = {
      left: clamp(
        right + 8,
        AI_MARGIN,
        wrapperRect.width - AI_SPARKLE_PX - AI_MARGIN,
      ),
      top: clamp(
        top - 8,
        AI_MARGIN,
        wrapperRect.height - AI_SPARKLE_PX - AI_MARGIN,
      ),
    };
    let cardLeft = sparkle.left;
    let cardTop = sparkle.top;
    if (cardLeft + AI_CARD_W > wrapperRect.width - AI_MARGIN) {
      cardLeft = sparkle.left + AI_SPARKLE_PX - AI_CARD_W;
    }
    if (cardTop + AI_CARD_H > wrapperRect.height - AI_MARGIN) {
      cardTop = sparkle.top + AI_SPARKLE_PX - AI_CARD_H;
    }
    const card = {
      left: clamp(cardLeft, AI_MARGIN, wrapperRect.width - AI_CARD_W - AI_MARGIN),
      top: clamp(cardTop, AI_MARGIN, wrapperRect.height - AI_CARD_H - AI_MARGIN),
    };
    setAiPos({ sparkle, card });
  }, [camera, spec, selectedIds, popout, activeScreenId, wrapperEpoch]);

  // screenId → derived export filename for the title-row chip. Derived live —
  // the export target is order-dependent and never stored on the spec.
  const screenFiles = useMemo(() => screenFileNames(spec), [spec]);

  // ── Moveable target list ──────────────────────────────────────────────
  // We rebuild on every render keyed by selectedIds; React → DOM reconciliation
  // has settled by the time Moveable reads its `target` prop.
  const targetElements = useMemo(() => {
    return selectedIds
      .map((id) => nodeRefs.current.get(id))
      .filter((el): el is HTMLDivElement => Boolean(el));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedIds, spec]);

  // Reposition Moveable's overlay after layout/spec changes.
  useEffect(() => {
    moveableRef.current?.updateTarget?.();
  }, [spec, selectedIds]);

  // Element guidelines for snap — every node currently rendered, minus the
  // ones being dragged.
  const guidelineElements = useMemo(() => {
    const all: HTMLDivElement[] = [];
    for (const el of nodeRefs.current.values()) all.push(el);
    return all.filter((el) => !targetElements.includes(el));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [targetElements, spec]);

  // ── Drag / resize handlers ────────────────────────────────────────────
  // During drag/resize we mutate the DOM directly for smoothness; on end we
  // commit final geometry to spec (origin + delta) and pin the wrapper's
  // inline left/top/width/height to the same values before queuing the spec
  // update. Pinning matters: React's reconciler skips writing same-value
  // style props, so a naive "clear inline overrides; let React's render
  // restore" sequence ends up clearing whatever onResize/onDrag set without
  // React putting anything back — the wrapper briefly has no width/height
  // and collapses to its content's intrinsic size, which the user perceives
  // as the element snapping to its original aspect ratio. The origin is
  // captured on *Start so a server-driven `set` arriving mid-gesture can't
  // shift the base.

  // Restore the inline geometry of a target whose gesture didn't commit.
  // React's prev-render tracked values match `origin`, so its diff would
  // skip writing — we have to put the values back ourselves. Without an
  // origin (gesture started outside our normal flow) we just clear the
  // overrides and hope the next render touches the styles.
  const restoreInlineGeometry = (
    target: HTMLElement,
    origin: { x: number; y: number; width: number; height: number } | undefined,
  ) => {
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
  };

  // The AI island hides for the duration of a gesture — imperatively, no
  // setState mid-drag; the [spec]-keyed anchoring effect re-positions on
  // commit.
  const hideAiIsland = () => {
    if (aiIslandRef.current) aiIslandRef.current.style.visibility = 'hidden';
  };
  const showAiIsland = () => {
    if (aiIslandRef.current) aiIslandRef.current.style.visibility = '';
  };

  const onDragStart = useCallback(
    (e: OnDragStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      const id = (e.target as HTMLElement).getAttribute('data-mock-id');
      if (id) stashOrigin(id);
    },
    [stashOrigin],
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
    [updateNode],
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
    [stashOrigin],
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
    [updateNodes],
  );

  const onResizeStart = useCallback(
    (e: OnResizeStart) => {
      gestureActiveRef.current = true;
      hideAiIsland();
      const id = (e.target as HTMLElement).getAttribute('data-mock-id');
      if (id) stashOrigin(id);
    },
    [stashOrigin],
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
      if (
        !origin ||
        !before ||
        !Number.isFinite(w) ||
        !Number.isFinite(h)
      ) {
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
    [updateNode],
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
    [stashOrigin],
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
    [updateNodes],
  );

  // ── Render ────────────────────────────────────────────────────────────
  const isEmpty = spec.screens.length === 0;

  return (
    <div
      ref={wrapperRef}
      className="relative h-full w-full bg-background"
      onPointerEnter={() => {
        pointerOverRef.current = true;
      }}
      onPointerLeave={() => {
        pointerOverRef.current = false;
      }}
    >
      {/* Camera viewport — the content layer pans/zooms inside it. */}
      <div
        ref={viewportRef}
        className={cn(
          'absolute inset-0 overflow-hidden overscroll-none',
          grabbing && 'cursor-grabbing',
        )}
        onPointerDown={onViewportPointerDown}
        onPointerMove={movePan}
        onPointerUp={endPan}
        onPointerCancel={endPan}
      >
        {isEmpty ? (
          <EmptyState />
        ) : (
          <div
            ref={contentRef}
            // w-max is load-bearing: an absolutely-positioned box's auto
            // width caps at the containing block, which would corrupt the
            // fit math (offsetWidth/Height are the transform-independent
            // content size fitToContent measures).
            className="absolute left-0 top-0 flex w-max origin-top-left items-start gap-20 p-10"
            style={{
              transform: `translate(${camera.x}px, ${camera.y}px) scale(${camera.zoom})`,
              willChange: 'transform',
            }}
            onPointerDown={(e) => {
              // Clicks in the gutters between/around frames (not on a node
              // or a frame) clear selection, same as the viewport background.
              if (e.button === 0 && e.target === e.currentTarget) {
                clearSelection();
              }
            }}
          >
            {spec.screens.map((screen) => (
          <div key={screen.id} className="flex flex-col gap-2">
            {/* This row must stay single-line: FRAME_INSET_Y in UIPanel.tsx
                mirrors its ~24px height. */}
            <div
              className={cn(
                'cursor-pointer whitespace-nowrap text-xs font-medium hover:text-foreground',
                screen.id === activeScreenId
                  ? 'text-foreground'
                  : 'text-foreground/90',
              )}
              onPointerDown={() => selectScreen(screen.id)}
            >
              {screen.title}
              <span className="ml-2 font-mono text-[10px] text-muted-foreground">
                {screen.frame.w}×{screen.frame.h}
              </span>
              <ScreenFileChip
                sourceFile={screen.sourceFile}
                exportName={screenFiles.get(screen.id)!}
              />
            </div>
            <div
              ref={(el) => {
                if (el) screenRefs.current.set(screen.id, el);
                else screenRefs.current.delete(screen.id);
              }}
              className="relative bg-background"
              data-screen-id={screen.id}
              style={{
                width: screen.frame.w,
                height: screen.frame.h,
                boxShadow:
                  '0 0 0 1px rgb(64 64 64), 0 24px 48px -16px rgb(0 0 0 / 0.6)',
              }}
              onPointerDown={(e) => {
                // Clicks on the frame background (not on a node) clear
                // selection and mark this screen as the user's working
                // screen. Bubbles up from node wrappers stop with their own
                // stopPropagation, so this only fires for the frame itself.
                if (e.target === e.currentTarget) {
                  clearSelection();
                  reportActiveScreen(screen.id);
                }
              }}
            >
              {screen.nodes.map((node) => (
                <NodeWrapper
                  key={node.id}
                  node={node}
                  isSelected={selectedIds.includes(node.id)}
                  isEditing={editingId === node.id}
                  refsMap={nodeRefs}
                  onSelectOnly={selectOnly}
                  onAddSelection={addToSelection}
                  onStartEditing={startEditing}
                  onCommitText={commitNodeText}
                  onEndEdit={stopEditing}
                />
              ))}
            </div>
          </div>
            ))}
          </div>
        )}

        {targetElements.length > 0 && (
          <Moveable
            ref={moveableRef}
          target={targetElements}
          draggable
          resizable
          // Snap to other elements' edges/centers and to drag distance.
          snappable
          snapDirections={{
            top: true,
            bottom: true,
            left: true,
            right: true,
            center: true,
            middle: true,
          }}
          elementSnapDirections={{
            top: true,
            bottom: true,
            left: true,
            right: true,
            center: true,
            middle: true,
          }}
          elementGuidelines={guidelineElements}
          throttleDrag={0}
          throttleResize={0}
          // Disable transforms while editing — clicks should land in the
          // contentEditable, not start a drag.
          edgeDraggable={!editingId}
          origin={false}
          renderDirections={
            editingId ? [] : ['nw', 'n', 'ne', 'w', 'e', 'sw', 's', 'se']
          }
          onDragStart={onDragStart}
          onDrag={onDrag}
          onDragEnd={onDragEnd}
          onDragGroupStart={onDragGroupStart}
          onDragGroup={onDragGroup}
          onDragGroupEnd={onDragGroupEnd}
          onResizeStart={onResizeStart}
          onResize={onResize}
          onResizeEnd={onResizeEnd}
          onResizeGroupStart={onResizeGroupStart}
          onResizeGroup={onResizeGroup}
            onResizeGroupEnd={onResizeGroupEnd}
          />
        )}

        {/* Space-held pan mode: a capture overlay above Moveable's handles
            (but below the floating controls) so a space-drag can't grab a
            node. Pointer capture lands on the viewport (beginPan), so the
            drag survives this overlay unmounting on keyup. */}
        {spaceHeld && (
          <div
            className={cn(
              'absolute inset-0',
              grabbing ? 'cursor-grabbing' : 'cursor-grab',
            )}
            style={{ zIndex: 3500 }}
            onPointerDown={(e) => {
              if (e.button !== 0) return;
              e.preventDefault();
              beginPan(e);
            }}
          />
        )}
      </div>

      {/* Floating element/layer controls. The wrapper is click-through; only
          the controls themselves capture pointer events, and they sit above
          Moveable's handles. */}
      <div
        className="pointer-events-none absolute inset-0"
        style={{ zIndex: 4000 }}
      >
        <div className="pointer-events-auto absolute left-3 top-3">
          {addOpen ? (
            <UIAddPalette
              onAdd={addNodeOfType}
              onClose={() => setAddOpen(false)}
              disabled={isEmpty}
            />
          ) : (
            <Button
              size="sm"
              variant="secondary"
              className="shadow-md"
              onClick={() => setAddOpen(true)}
            >
              <Plus className="size-3.5" />
              Add
            </Button>
          )}
        </div>
        {/* AI sparkle/popout island. Zero-size at the layer origin so its
            absolutely-positioned children land in wrapper coords; one ref so
            gestures can hide the whole thing imperatively. */}
        <div ref={aiIslandRef} className="pointer-events-auto absolute left-0 top-0">
          {!popout &&
            !editingId &&
            aiPos.sparkle &&
            (selectedIds.length > 0 ||
              (selectedIds.length === 0 && activeScreenId && !isEmpty)) && (
              <button
                type="button"
                aria-label="Ask AI"
                className="absolute flex size-7 items-center justify-center rounded-full bg-primary text-primary-foreground shadow-md transition hover:scale-105"
                style={{ left: aiPos.sparkle.left, top: aiPos.sparkle.top }}
                onClick={() =>
                  selectedIdsRef.current.length > 0
                    ? openPopoutForSelection()
                    : openPopoutForScreen(activeScreenId!)
                }
              >
                <Sparkles className="size-3.5" />
              </button>
            )}
          {popout && aiPos.card && (
            <UIAIPopout
              scope={popout.scope}
              position={aiPos.card}
              onClose={closePopout}
            />
          )}
        </div>
        <div className="pointer-events-auto absolute bottom-3 left-3">
          <ZoomControls
            zoom={camera.zoom}
            disabled={isEmpty}
            onZoomStep={zoomStep}
            onZoomTo={zoomTo}
            onFit={fitToContent}
          />
        </div>
        <div className="pointer-events-auto absolute bottom-3 right-3 top-3 flex items-start">
          {layersOpen ? (
            <UILayersPanel
              screens={spec.screens}
              selectedIds={selectedIds}
              activeScreenId={activeScreenId}
              onSelect={handleLayerSelect}
              onReorder={reorderNode}
              onRemove={removeNode}
              onSelectScreen={selectScreen}
              onAiForScreen={openPopoutForScreen}
              onRemoveScreen={removeScreen}
              onClose={() => setLayersOpen(false)}
            />
          ) : (
            <Button
              size="sm"
              variant="secondary"
              className="shadow-md"
              onClick={() => setLayersOpen(true)}
            >
              <Layers className="size-3.5" />
              Layers
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

// Memoized: with uiMockOps preserving node identity for untouched nodes and
// every callback prop useCallback-stable in the parent, a drag/selection
// change re-renders only the affected nodes instead of the whole canvas.
const NodeWrapper = memo(function NodeWrapper({
  node,
  isSelected,
  isEditing,
  refsMap,
  onSelectOnly,
  onAddSelection,
  onStartEditing,
  onCommitText,
  onEndEdit,
}: {
  node: UINode;
  isSelected: boolean;
  isEditing: boolean;
  refsMap: RefObject<Map<string, HTMLDivElement>>;
  onSelectOnly: (id: string) => void;
  onAddSelection: (id: string) => void;
  onStartEditing: (id: string) => void;
  onCommitText: (id: string, text: string) => void;
  onEndEdit: () => void;
}) {
  // Callback ref keeps the refs map in sync with the live DOM. We register on
  // mount and unregister on unmount; React calls the callback with `null` on
  // unmount so the cleanup is automatic.
  const setRef = useCallback(
    (el: HTMLDivElement | null) => {
      const map = refsMap.current;
      if (!map) return;
      if (el) {
        map.set(node.id, el);
      } else {
        map.delete(node.id);
      }
    },
    [node.id, refsMap],
  );

  const onPointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      // Don't kick selection while the user is editing text.
      if (isEditing) return;
      // Stop the canvas-level click-to-deselect from firing.
      e.stopPropagation();
      if (e.shiftKey || e.metaKey || e.ctrlKey) {
        onAddSelection(node.id);
      } else if (!isSelected) {
        onSelectOnly(node.id);
      }
    },
    [isEditing, isSelected, node.id, onAddSelection, onSelectOnly],
  );

  const onDoubleClick = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      if (!isTextual(node)) return;
      e.stopPropagation();
      onStartEditing(node.id);
    },
    [node, onStartEditing],
  );

  const commitText = useCallback(
    (text: string) => onCommitText(node.id, text),
    [node.id, onCommitText],
  );

  const style: CSSProperties = {
    position: 'absolute',
    left: node.x,
    top: node.y,
    width: node.width,
    height: node.height,
  };

  return (
    <div
      ref={setRef}
      data-mock-id={node.id}
      className={cn(
        'box-border',
        isSelected && 'ring-1 ring-ring/50',
      )}
      style={style}
      onPointerDown={onPointerDown}
      onDoubleClick={onDoubleClick}
    >
      <UIMockNode
        node={node}
        isEditing={isEditing}
        onCommitText={commitText}
        onEndEdit={onEndEdit}
      />
    </div>
  );
});

// Directional provenance chip in the screen title row: '↓ <basename>' when
// the screen was imported from a Swift source, else '↑ <TypeName>.swift' (the
// derived export target). Click copies the relevant workspace-relative path.
// Renders inside the transformed title row, so it scales with zoom — accepted
// (informational only; all triggers live in screen space).
function ScreenFileChip({
  sourceFile,
  exportName,
}: {
  sourceFile?: string;
  exportName: string;
}) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<number | null>(null);
  useEffect(() => {
    return () => {
      if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    };
  }, []);

  return (
    <button
      type="button"
      className="ml-2 inline-flex max-w-40 items-center gap-0.5 truncate align-bottom font-mono text-[10px] text-muted-foreground hover:text-foreground"
      title={`Imported from: ${sourceFile ?? '—'}\nExports to: TangoGenerated/${exportName}`}
      // Keep the copy click from also activating the screen via the row.
      onPointerDown={(e) => e.stopPropagation()}
      onClick={() => {
        void navigator.clipboard.writeText(
          sourceFile ?? `TangoGenerated/${exportName}`,
        );
        setCopied(true);
        if (timerRef.current !== null) window.clearTimeout(timerRef.current);
        timerRef.current = window.setTimeout(() => setCopied(false), 1200);
      }}
    >
      {copied ? (
        <>
          <Check className="size-3" />
          copied
        </>
      ) : sourceFile ? (
        `↓ ${basename(sourceFile)}`
      ) : (
        `↑ ${exportName}`
      )}
    </button>
  );
}

function basename(path: string): string {
  const i = path.lastIndexOf('/');
  return i === -1 ? path : path.slice(i + 1);
}

// Shared guard for the window-level key listeners: don't hijack keys headed
// for a text edit or a focused control (space activates a focused button).
function isTypingTarget(t: EventTarget | null): boolean {
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

function findNode(spec: UISpec, id: string): UINode | null {
  for (const screen of spec.screens) {
    for (const node of screen.nodes) {
      if (node.id === id) return node;
    }
  }
  return null;
}

function isTextual(node: UINode): boolean {
  return (
    node.type === 'text' ||
    node.type === 'heading' ||
    node.type === 'Button' ||
    node.type === 'Badge'
  );
}

// Figma-style zoom readout: −/+ step around the viewport center, clicking
// the percentage resets to 100%, Fit reframes the whole spec.
function ZoomControls({
  zoom,
  disabled,
  onZoomStep,
  onZoomTo,
  onFit,
}: {
  zoom: number;
  disabled: boolean;
  onZoomStep: (factor: number) => void;
  onZoomTo: (zoom: number) => void;
  onFit: () => void;
}) {
  return (
    <div className="flex items-center gap-0.5 rounded-md bg-secondary p-0.5 text-secondary-foreground shadow-md">
      <Button
        size="sm"
        variant="ghost"
        className="size-7 px-0"
        disabled={disabled || zoom <= MIN_ZOOM}
        onClick={() => onZoomStep(1 / 1.25)}
        title="Zoom out (⌘−)"
      >
        <Minus className="size-3.5" />
      </Button>
      <button
        type="button"
        className="w-12 rounded-sm px-1 py-1 text-center font-mono text-[11px] tabular-nums hover:bg-secondary-foreground/10 disabled:pointer-events-none disabled:opacity-50"
        disabled={disabled}
        onClick={() => onZoomTo(1)}
        title="Reset to 100% (⌘0)"
      >
        {Math.round(zoom * 100)}%
      </button>
      <Button
        size="sm"
        variant="ghost"
        className="size-7 px-0"
        disabled={disabled || zoom >= MAX_ZOOM}
        onClick={() => onZoomStep(1.25)}
        title="Zoom in (⌘+)"
      >
        <Plus className="size-3.5" />
      </Button>
      <Button
        size="sm"
        variant="ghost"
        className="size-7 px-0"
        disabled={disabled}
        onClick={onFit}
        title="Zoom to fit (⇧1)"
      >
        <Maximize className="size-3.5" />
      </Button>
    </div>
  );
}

function EmptyState() {
  return (
    <div className="flex h-full w-full items-center justify-center bg-background p-8 text-center text-sm text-muted-foreground">
      <div className="max-w-md space-y-2">
        <p className="font-medium text-foreground">UI mock is empty.</p>
        <p>
          Ask the terminal agent to{' '}
          <span className="rounded bg-muted px-1 font-mono text-foreground/90">
            “mock my settings page as a UI”
          </span>{' '}
          (or any other screen / flow). The agent will read your codebase and write
          a shadcn-based mock here that you can drag, resize, and edit, then
          send back as a reference for the real UI.
        </p>
      </div>
    </div>
  );
}
