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
  type PointerEvent as ReactPointerEvent,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { createPortal } from 'react-dom';
import Moveable from 'react-moveable';
import { Plus, Sparkles } from 'lucide-react';
import NodeWrapper from './canvas/NodeWrapper';
import { useCanvasCamera } from './canvas/useCanvasCamera';
import { useDrawTool } from './canvas/useDrawTool';
import { useMoveableGestures } from './canvas/useMoveableGestures';
import {
  EmptyState,
  ScreenFileChip,
  ScreenRefreshButton,
  ShapeToolbar,
  ZoomControls,
} from './canvas/CanvasChrome';
import UIAddPalette from './UIAddPalette';
import UIAIPopout from './UIAIPopout';
import UILayersPanel from './UILayersPanel';
import { Button } from './ui/button';
import { uiMockBus } from '@/lib/uiMockBus';
import type { ApplyMsg } from '@/lib/uiMockBus';
import {
  addNodesToScreen,
  findNodeInSpec,
  groupNodesInSpec,
  instantiateComponentInSpec,
  moveGroupInSpec,
  moveNodeInSpec,
  removeNodesFromSpec,
  removeScreenFromSpec,
  renameGroupInSpec,
  reorderNodeInSpec,
  ungroupNodesInSpec,
  type ReorderOp,
} from '@/lib/uiMockOps';
import { screenFileNames } from '@/lib/specToSwiftUI';
import type { AgentTask } from '@/lib/terminalBus';
import { NODE_DEFAULTS, isShapeType, makeNode } from '@/lib/uiMockDefaults';
import { isLineTool } from '@/lib/shapeDraw';
import UIShapeStyleBar from './UIShapeStyleBar';
import UIInspector from './UIInspector';
import {
  EMPTY_SPEC,
  type SourceSyncStatus,
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
  // Refresh one screen from its linked source file (the title-row refresh
  // action) — UIPanel runs the scoped import and owns the status line.
  onReimportScreen?: (screenId: string, sourceFile: string) => void;
  // UIPanel's docked sidebar slot. When present, the layers tree + inspector
  // portal into it (state lives here, layout lives in UIPanel so the canvas
  // viewport measurement excludes the sidebar). Null = sidebar closed.
  sidebarContainer?: HTMLDivElement | null;
};

export default function UIMockCanvas({
  initialSpec,
  onPersist,
  onActiveScreen,
  onReimportScreen,
  sidebarContainer,
}: Props) {
  const [spec, setSpec] = useState<UISpec>(initialSpec ?? EMPTY_SPEC);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [editingId, setEditingId] = useState<string | null>(null);
  // Floating overlay visibility — the Add palette.
  const [addOpen, setAddOpen] = useState(false);
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
  // Server-applied (agent) changes flash briefly so the user can see exactly
  // what the agent touched as edits stream in.
  const [pulse, setPulse] = useState<{
    nodes: Set<string>;
    screens: Set<string>;
  }>(() => ({ nodes: new Set(), screens: new Set() }));
  const pulseTimer = useRef<number | null>(null);
  // Per-screen source-file sync ('synced' | 'stale' | 'missing'), pushed by
  // the server's watcher over /ws/ui-mock. Absent id = unlinked screen.
  const [sourceSync, setSourceSync] = useState<
    Record<string, SourceSyncStatus>
  >({});

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

  // Tracks whether the next spec render came from a server-driven apply.
  // We bump this when an apply lands and skip one snapshot effect run — the
  // server cache is already in this state, no need to bounce it back. The
  // bridge wouldn't re-broadcast the snapshot, but skipping the round-trip
  // keeps the wire quiet.
  const skipNextSnapshot = useRef(false);

  // ── Server → browser apply ─────────────────────────────────────────────
  useEffect(() => {
    const flashPulse = (nodes: Set<string>, screens: Set<string>): void => {
      if (nodes.size === 0 && screens.size === 0) return;
      setPulse({ nodes, screens });
      if (pulseTimer.current !== null) window.clearTimeout(pulseTimer.current);
      pulseTimer.current = window.setTimeout(() => {
        pulseTimer.current = null;
        setPulse({ nodes: new Set(), screens: new Set() });
      }, 1100);
    };
    const unsubscribe = uiMockBus._onApply((msg: ApplyMsg) => {
      if (msg.type === 'set') {
        // Diff against the outgoing spec so agent-touched nodes/screens flash.
        const prev = specRef.current;
        const prevNodes = new Map<string, UINode>();
        for (const s of prev.screens) for (const n of s.nodes) prevNodes.set(n.id, n);
        const prevScreens = new Set(prev.screens.map((s) => s.id));
        const pulseNodes = new Set<string>();
        const pulseScreens = new Set<string>();
        for (const s of msg.spec.screens) {
          if (!prevScreens.has(s.id)) {
            pulseScreens.add(s.id);
            continue;
          }
          for (const n of s.nodes) {
            const old = prevNodes.get(n.id);
            if (!old) pulseNodes.add(n.id);
            else if (old !== n && JSON.stringify(old) !== JSON.stringify(n)) {
              pulseNodes.add(n.id);
            }
          }
        }
        flashPulse(pulseNodes, pulseScreens);
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
        flashPulse(new Set(), new Set([msg.screen.id]));
        skipNextSnapshot.current = true;
        setSpec((prev) => ({
          ...prev,
          screens: [...prev.screens, msg.screen],
        }));
      } else if (msg.type === 'source_sync') {
        setSourceSync(msg.statuses);
      }
    });
    return () => {
      unsubscribe();
      if (pulseTimer.current !== null) window.clearTimeout(pulseTimer.current);
    };
  }, []);

  // ── Browser → server snapshot (debounced) ──────────────────────────────
  // We skip:
  //   - the very first commit (initial spec / hydration from localStorage)
  //   - any commit triggered by a server-driven apply (skipNextSnapshot)
  // Everything else (drag/resize/text edit/delete) fires a debounced emit.
  // onPersist runs SYNCHRONOUSLY on every commit (not inside the debounce):
  // UIPanel's specRef must always hold the live spec — Export & Run ships it
  // with the POST so an edit made <250ms before the click is never lost.
  const isFirstCommit = useRef(true);
  useEffect(() => {
    if (isFirstCommit.current) {
      isFirstCommit.current = false;
      return;
    }
    onPersist(spec);
    if (skipNextSnapshot.current) {
      // Server-driven apply: persisted locally so a refresh keeps the
      // content; don't bounce the snapshot back up the WS.
      skipNextSnapshot.current = false;
      return;
    }
    const timer = window.setTimeout(() => {
      uiMockBus._emitSnapshot(spec);
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

  // Group-aware canvas click (Figma semantics): plain click on a grouped node
  // selects the whole group; Cmd/Ctrl+click deep-selects the single node;
  // Shift+click stays additive. A plain click on an already-selected node is
  // a no-op so a drag can follow without collapsing a multi-selection.
  const selectFromPointer = useCallback(
    (id: string, mode: 'replace' | 'additive' | 'deep') => {
      if (mode === 'additive') {
        addToSelection(id);
        return;
      }
      if (mode === 'deep') {
        selectOnly(id);
        return;
      }
      if (selectedIdsRef.current.includes(id)) return;
      const screen = specRef.current.screens.find((s) =>
        s.nodes.some((n) => n.id === id),
      );
      const node = screen?.nodes.find((n) => n.id === id);
      if (screen && node?.group) {
        const members = screen.nodes
          .filter((n) => n.group === node.group)
          .map((n) => n.id);
        setSelectedIds(members);
        setEditingId(null);
        reportActiveScreen(screen.id);
        return;
      }
      selectOnly(id);
    },
    [addToSelection, selectOnly, reportActiveScreen],
  );

  // Select every member of a group (layers-tree group row click). Group ids
  // are only unique per screen, so the panel passes the owning screen.
  const selectGroup = useCallback(
    (groupId: string, screenId: string) => {
      const screen = specRef.current.screens.find((s) => s.id === screenId);
      if (!screen) return;
      setSelectedIds(
        screen.nodes.filter((n) => n.group === groupId).map((n) => n.id),
      );
      setEditingId(null);
      reportActiveScreen(screen.id);
    },
    [reportActiveScreen],
  );

  // Cmd+G: group the selection on its (first) screen. Nodes from other
  // screens are dropped from the group, mirroring the AI popout's scoping.
  const groupSelection = useCallback(() => {
    const ids = selectedIdsRef.current;
    if (ids.length < 2) return;
    const screen = specRef.current.screens.find((s) =>
      s.nodes.some((n) => n.id === ids[0]),
    );
    if (!screen) return;
    const onScreen = ids.filter((id) =>
      screen.nodes.some((n) => n.id === id),
    );
    if (onScreen.length < 2) return;
    try {
      setSpec(groupNodesInSpec(specRef.current, screen.id, onScreen));
    } catch {
      // node vanished mid-keystroke (server-driven set) — ignore.
    }
  }, []);

  // Cmd+Shift+G: dissolve every group the selection touches — addressed as
  // (screen, group) pairs, since group ids repeat across screens.
  const ungroupSelection = useCallback(() => {
    const ids = new Set(selectedIdsRef.current);
    const pairs = new Map<string, { screenId: string; groupId: string }>();
    for (const s of specRef.current.screens) {
      for (const n of s.nodes) {
        if (ids.has(n.id) && n.group) {
          pairs.set(`${s.id} ${n.group}`, { screenId: s.id, groupId: n.group });
        }
      }
    }
    if (pairs.size === 0) return;
    try {
      let next = specRef.current;
      for (const { screenId, groupId } of pairs.values()) {
        next = ungroupNodesInSpec(next, groupId, screenId);
      }
      setSpec(next);
    } catch {
      // group vanished mid-keystroke — ignore.
    }
  }, []);

  const renameGroup = useCallback(
    (groupId: string, name: string, screenId: string) => {
      try {
        setSpec(renameGroupInSpec(specRef.current, groupId, name, screenId));
      } catch {
        // empty name or vanished group — ignore.
      }
    },
    [],
  );

  const moveNode = useCallback(
    (
      nodeId: string,
      targetIndex: number,
      group?: string | null,
      targetScreenId?: string,
    ) => {
      try {
        setSpec(
          moveNodeInSpec(specRef.current, nodeId, targetIndex, group, targetScreenId),
        );
      } catch {
        // node/group/screen vanished between drag start and drop — ignore.
      }
    },
    [],
  );

  const moveGroup = useCallback(
    (
      groupId: string,
      targetIndex: number,
      sourceScreenId: string,
      targetScreenId?: string,
    ) => {
      try {
        setSpec(
          moveGroupInSpec(
            specRef.current,
            groupId,
            targetIndex,
            targetScreenId,
            sourceScreenId,
          ),
        );
      } catch {
        // group/screen vanished between drag start and drop — ignore.
      }
    },
    [],
  );

  const ungroup = useCallback((groupId: string, screenId: string) => {
    try {
      setSpec(ungroupNodesInSpec(specRef.current, groupId, screenId));
    } catch {
      // already gone — ignore.
    }
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

  // Inspector / style-bar channel: each patch is COMPUTED from the live node
  // inside the state updater, not from the caller's (possibly stale) props —
  // two edits landing in the same tick compose instead of the second
  // clobbering the first. (`updateNodes` above stays for gesture commits,
  // whose patches are origin+delta geometry and must NOT be re-derived from
  // the live spec mid-flight.)
  const applyNodePatches = useCallback(
    (ids: string[], fn: (node: UINode) => Partial<UINode>) => {
      const wanted = new Set(ids);
      if (wanted.size === 0) return;
      setSpec((prev) => ({
        ...prev,
        screens: prev.screens.map((screen) => {
          if (!screen.nodes.some((n) => wanted.has(n.id))) return screen;
          return {
            ...screen,
            nodes: screen.nodes.map((node) =>
              wanted.has(node.id)
                ? { ...node, ...fn(node), id: node.id }
                : node,
            ),
          };
        }),
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

  // Stamp an imported design-library component into the working screen —
  // same placement policy as addNodeOfType; the pure op mints fresh ids and
  // wraps the instance in a group named after the component.
  const addComponentInstance = useCallback(
    (componentId: string) => {
      const current = specRef.current;
      if (current.screens.length === 0) return;
      const target =
        current.screens.find((s) =>
          s.nodes.some((n) => selectedIds.includes(n.id)),
        ) ?? current.screens[0];
      const stagger = (target.nodes.length % 6) * 24;
      try {
        const result = instantiateComponentInSpec(
          current,
          componentId,
          target.id,
          { x: 24 + stagger, y: 24 + stagger },
        );
        setSpec(result.spec);
        setSelectedIds(result.nodeIds);
        setEditingId(null);
      } catch {
        // component/screen vanished between render and click — ignore.
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

  // Keyboard z-order over the whole selection, moving it as a CLUSTER.
  // Processing order preserves relative stacking — forward/back start from
  // the topmost node, backward/front from the bottommost (front/back invert:
  // each successive jump-to-extreme lands ON TOP of / BELOW the previously
  // processed one) — and a single-step move is skipped when the node it
  // would swap past is itself selected, so adjacent selected nodes never
  // trade places.
  const reorderSelection = useCallback((op: ReorderOp) => {
    const ids = selectedIdsRef.current;
    if (ids.length === 0) return;
    const selected = new Set(ids);
    const locate = (
      spec: UISpec,
      id: string,
    ): { nodes: UISpec['screens'][number]['nodes']; idx: number } | null => {
      for (const s of spec.screens) {
        const i = s.nodes.findIndex((n) => n.id === id);
        if (i !== -1) return { nodes: s.nodes, idx: i };
      }
      return null;
    };
    const zOf = (id: string): number => locate(specRef.current, id)?.idx ?? -1;
    const topFirst = op === 'forward' || op === 'back';
    const ordered = [...ids].sort((a, b) =>
      topFirst ? zOf(b) - zOf(a) : zOf(a) - zOf(b),
    );
    try {
      let next = specRef.current;
      for (const id of ordered) {
        if (op === 'forward' || op === 'backward') {
          const at = locate(next, id);
          if (!at) continue;
          const neighbor = at.nodes[op === 'forward' ? at.idx + 1 : at.idx - 1];
          if (neighbor && selected.has(neighbor.id)) continue; // cluster moves together
        }
        next = reorderNodeInSpec(next, id, op);
      }
      setSpec(next);
    } catch {
      // node vanished mid-keystroke (server-driven set) — ignore.
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

  // ── Camera (pan / zoom) ───────────────────────────────────────────────
  // Extracted to useCanvasCamera — view-only state; never enters the spec.
  const screenCount = spec.screens.length;
  const {
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
  } = useCanvasCamera({
    editingId,
    screenCount,
    specRef,
    onBackgroundClick: clearSelection,
  });

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

  // ── Draw tools (vector shapes) ────────────────────────────────────────
  // Extracted to useDrawTool; the canvas owns the spec/selection commit.
  const commitDrawnNode = useCallback(
    (screenId: string, node: UINode) => {
      try {
        setSpec(addNodesToScreen(specRef.current, screenId, [node]));
        setSelectedIds([node.id]);
        setEditingId(null);
        reportActiveScreen(screenId);
      } catch {
        // id collision is effectively impossible with a random uuid; ignore.
      }
    },
    [reportActiveScreen],
  );

  const {
    tool,
    rubber,
    armTool,
    disarm: disarmDrawTool,
    cancelDraw,
    onDrawPointerDown,
    onDrawPointerMove,
    onDrawPointerUp,
  } = useDrawTool({
    cameraZoom: camera.zoom,
    screenRefs,
    specRef,
    gestureActiveRef,
    onCommit: commitDrawnNode,
  });

  // ── Keyboard ──────────────────────────────────────────────────────────
  // Lives below the camera + draw-tool sections: the handler reads
  // pointerOverRef / tool / armTool, which must be initialized first.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Don't steal Backspace/Delete while the user is editing text.
      if (editingId) return;
      const target = e.target as HTMLElement | null;
      if (target && (target.isContentEditable || target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) {
        return;
      }
      // Cmd+G groups the selection; Cmd+Shift+G ungroups. Before the draw
      // shortcuts (whose guard skips modified keys anyway) and gated on a
      // selection so the browser's own Cmd+G keeps working otherwise.
      if (
        (e.metaKey || e.ctrlKey) &&
        e.key.toLowerCase() === 'g' &&
        selectedIds.length > 0
      ) {
        e.preventDefault();
        if (e.shiftKey) ungroupSelection();
        else groupSelection();
        return;
      }
      // Z-order: Cmd+] / Cmd+[ move forward/backward, +Alt jumps to
      // front/back (Figma keys). e.code, not e.key — macOS Option composes
      // the bracket keys into different characters.
      if (
        (e.metaKey || e.ctrlKey) &&
        (e.code === 'BracketRight' || e.code === 'BracketLeft') &&
        selectedIds.length > 0
      ) {
        e.preventDefault();
        const up = e.code === 'BracketRight';
        reorderSelection(up ? (e.altKey ? 'front' : 'forward') : e.altKey ? 'back' : 'backward');
        return;
      }
      // Escape priority: armed draw tool → popout → selection.
      if (e.key === 'Escape' && tool) {
        disarmDrawTool();
        return;
      }
      // Escape closes the popout first, the selection second. (With focus in
      // the popout's textarea the typing-target guard above returns early and
      // the popout's own onKeyDown handles it.)
      if (e.key === 'Escape' && popout) {
        setPopout(null);
        return;
      }
      // Draw-tool shortcuts (Figma keys), scoped to cursor-over-canvas like
      // the camera shortcuts so typing elsewhere never arms a tool.
      if (
        pointerOverRef.current &&
        !e.metaKey &&
        !e.ctrlKey &&
        !e.altKey &&
        !e.repeat &&
        specRef.current.screens.length > 0
      ) {
        const k = e.key.toLowerCase();
        if (k === 'r') {
          armTool('rect');
          return;
        }
        if (k === 'o') {
          armTool('ellipse');
          return;
        }
        if (k === 'l') {
          armTool(e.shiftKey ? 'arrow' : 'line');
          return;
        }
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
  }, [
    editingId,
    selectedIds.length,
    deleteSelected,
    clearSelection,
    popout,
    tool,
    armTool,
    disarmDrawTool,
    groupSelection,
    ungroupSelection,
    reorderSelection,
    pointerOverRef,
  ]);

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

  // The selected nodes (inspector) and their shape subset (quick style bar
  // when the sidebar is closed; patches only touch the shape nodes).
  const selectedNodes = useMemo(() => {
    const out: UINode[] = [];
    for (const id of selectedIds) {
      const node = findNodeInSpec(spec, id);
      if (node) out.push(node);
    }
    return out;
  }, [selectedIds, spec]);

  const shapeSelection = useMemo(
    () => selectedNodes.filter((n) => isShapeType(n.type)),
    [selectedNodes],
  );

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
  // Extracted to useMoveableGestures (origin+delta commits, inline-geometry
  // pinning — see the hook's header comment for the why).
  const gestureHandlers = useMoveableGestures({
    specRef,
    gestureActiveRef,
    aiIslandRef,
    updateNode,
    updateNodes,
  });

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
                syncStatus={sourceSync[screen.id]}
              />
              {screen.sourceFile && onReimportScreen && (
                <ScreenRefreshButton
                  screenId={screen.id}
                  sourceFile={screen.sourceFile}
                  syncStatus={sourceSync[screen.id]}
                  onReimport={onReimportScreen}
                />
              )}
            </div>
            <div
              ref={(el) => {
                if (el) screenRefs.current.set(screen.id, el);
                else screenRefs.current.delete(screen.id);
              }}
              className={cn(
                'relative bg-background',
                pulse.screens.has(screen.id) &&
                  'outline outline-2 outline-primary/70',
              )}
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
                  isPulsing={pulse.nodes.has(node.id)}
                  isEditing={editingId === node.id}
                  refsMap={nodeRefs}
                  onPointerSelect={selectFromPointer}
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
          {...gestureHandlers}
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

        {/* Draw-tool overlay: crosshair capture surface for the armed shape
            tool. Sits BELOW the space-pan overlay so space+drag still pans,
            and below the floating controls (4000) so the toolbar stays
            clickable to switch/disarm. */}
        {tool && !isEmpty && (
          <div
            className="absolute inset-0 cursor-crosshair touch-none"
            style={{ zIndex: 3400 }}
            onPointerDown={onDrawPointerDown}
            onPointerMove={onDrawPointerMove}
            onPointerUp={onDrawPointerUp}
            onPointerCancel={cancelDraw}
          >
            {rubber &&
              (isLineTool(tool) ? (
                <svg className="pointer-events-none absolute inset-0 h-full w-full overflow-visible">
                  <line
                    x1={rubber.start.x}
                    y1={rubber.start.y}
                    x2={rubber.cur.x}
                    y2={rubber.cur.y}
                    className="stroke-primary"
                    strokeWidth={1.5}
                    strokeDasharray="4"
                  />
                </svg>
              ) : (
                <div
                  className="pointer-events-none absolute border border-dashed border-primary bg-primary/10"
                  style={{
                    left: Math.min(rubber.start.x, rubber.cur.x),
                    top: Math.min(rubber.start.y, rubber.cur.y),
                    width: Math.abs(rubber.cur.x - rubber.start.x),
                    height: Math.abs(rubber.cur.y - rubber.start.y),
                  }}
                />
              ))}
          </div>
        )}
      </div>

      {/* Floating element/layer controls. The wrapper is click-through; only
          the controls themselves capture pointer events, and they sit above
          Moveable's handles. */}
      <div
        className="pointer-events-none absolute inset-0"
        style={{ zIndex: 4000 }}
      >
        <div className="pointer-events-auto absolute left-3 top-3 flex items-start gap-2">
          {addOpen ? (
            <UIAddPalette
              onAdd={addNodeOfType}
              onClose={() => setAddOpen(false)}
              disabled={isEmpty}
              components={spec.components?.map((c) => ({
                id: c.id,
                name: c.name,
              }))}
              onAddComponent={addComponentInstance}
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
          <ShapeToolbar tool={tool} disabled={isEmpty} onArm={armTool} />
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
        {/* Quick style bar: only when the docked sidebar (whose inspector
            subsumes it) is closed. */}
        {!sidebarContainer && shapeSelection.length > 0 && !editingId && (
          <div className="pointer-events-auto absolute bottom-3 left-1/2 -translate-x-1/2">
            <UIShapeStyleBar nodes={shapeSelection} onApply={applyNodePatches} />
          </div>
        )}
      </div>

      {/* Docked design sidebar (layers tree + inspector), portaled into
          UIPanel's slot so spec/selection state stays in this component. */}
      {sidebarContainer &&
        createPortal(
          <div className="flex h-full min-h-0 flex-col">
            <div className="min-h-0 flex-1 overflow-hidden">
              <UILayersPanel
                screens={spec.screens}
                selectedIds={selectedIds}
                activeScreenId={activeScreenId}
                onSelect={handleLayerSelect}
                onSelectGroup={selectGroup}
                onReorder={reorderNode}
                onRemove={removeNode}
                onMoveNode={moveNode}
                onMoveGroup={moveGroup}
                onRenameGroup={renameGroup}
                onUngroup={ungroup}
                onSelectScreen={selectScreen}
                onAiForScreen={openPopoutForScreen}
                onRemoveScreen={removeScreen}
              />
            </div>
            {selectedNodes.length > 0 && !editingId && (
              <div className="max-h-[55%] shrink-0 overflow-auto border-t border-border">
                <UIInspector nodes={selectedNodes} onApply={applyNodePatches} />
              </div>
            )}
          </div>,
          sidebarContainer,
        )}
    </div>
  );
}
