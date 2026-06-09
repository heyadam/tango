'use client';

// The core UI-mock renderer. Owns spec state, selection, drag/resize via
// react-moveable, text editing, and the snapshot-back-to-server flow. Sits
// behind a dynamic-import boundary in UIPanel because react-moveable touches
// `window` at module load.
//
// Coord model: every node sits at absolute pixel coords inside a per-screen
// frame. Frames are tiled left-to-right with a fixed gutter; the canvas is
// scrollable. No zoom in v1 — Moveable's drag math is 1:1 with frame coords,
// which keeps the resize/drag-end → spec write trivial.
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
import { Layers, Plus } from 'lucide-react';
import UIMockNode from './UIMockNode';
import UIAddPalette from './UIAddPalette';
import UILayersPanel from './UILayersPanel';
import { Button } from './ui/button';
import { uiMockBus } from '@/lib/uiMockBus';
import type { ApplyMsg } from '@/lib/uiMockBus';
import {
  addNodesToScreen,
  removeNodesFromSpec,
  reorderNodeInSpec,
  type ReorderOp,
} from '@/lib/uiMockOps';
import { NODE_DEFAULTS, makeNode } from '@/lib/uiMockDefaults';
import {
  EMPTY_SPEC,
  type UINode,
  type UINodeType,
  type UISpec,
} from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

const SNAPSHOT_DEBOUNCE_MS = 250;

type Props = {
  initialSpec: UISpec;
  onPersist: (spec: UISpec) => void;
};

export default function UIMockCanvas({ initialSpec, onPersist }: Props) {
  const [spec, setSpec] = useState<UISpec>(initialSpec ?? EMPTY_SPEC);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [editingId, setEditingId] = useState<string | null>(null);
  // Floating overlay visibility — the Add palette and Layers panel.
  const [addOpen, setAddOpen] = useState(false);
  const [layersOpen, setLayersOpen] = useState(false);

  // Map<nodeId, wrapper-element> populated by callback refs on each rendered
  // node so we can hand react-moveable real DOM targets without re-querying.
  const nodeRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  const moveableRef = useRef<Moveable | null>(null);

  // Latest spec snapshot for callbacks closing over stale refs (e.g. drag-end
  // handlers that fire long after they were attached).
  const specRef = useRef(spec);
  specRef.current = spec;

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
  const selectOnly = useCallback((id: string) => {
    setSelectedIds([id]);
    setEditingId(null);
  }, []);

  const addToSelection = useCallback((id: string) => {
    setSelectedIds((prev) => (prev.includes(id) ? prev : [...prev, id]));
    setEditingId(null);
  }, []);

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

  // ── Keyboard ──────────────────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Don't steal Backspace/Delete while the user is editing text.
      if (editingId) return;
      const target = e.target as HTMLElement | null;
      if (target && (target.isContentEditable || target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) {
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
  }, [editingId, selectedIds.length, deleteSelected, clearSelection]);

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

  const onDragStart = useCallback(
    (e: OnDragStart) => {
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
    <div className="relative h-full w-full bg-background">
      {/* Scrollable canvas surface. */}
      <div
        className="absolute inset-0 overflow-auto"
        onPointerDown={(e) => {
          // Clicks landing on the canvas background (not on a node wrapper)
          // clear selection and exit text edit mode.
          if (e.target === e.currentTarget) {
            clearSelection();
          }
        }}
      >
        {isEmpty ? (
          <EmptyState />
        ) : (
          <div
            className="relative flex items-start gap-20 p-10"
            // Push min-height so the flex container can expand to fit the
            // tallest frame even when the parent shrinks.
            style={{ minHeight: 'min-content' }}
          >
            {spec.screens.map((screen) => (
          <div key={screen.id} className="flex flex-col gap-2">
            <div className="text-xs font-medium text-foreground/90">
              {screen.title}
              <span className="ml-2 font-mono text-[10px] text-muted-foreground">
                {screen.frame.w}×{screen.frame.h}
              </span>
            </div>
            <div
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
                // selection. Bubbles up from node wrappers stop with their
                // own stopPropagation, so this only fires for the frame
                // itself.
                if (e.target === e.currentTarget) {
                  clearSelection();
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
        <div className="pointer-events-auto absolute bottom-3 right-3 top-3 flex items-start">
          {layersOpen ? (
            <UILayersPanel
              screens={spec.screens}
              selectedIds={selectedIds}
              onSelect={handleLayerSelect}
              onReorder={reorderNode}
              onRemove={removeNode}
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
