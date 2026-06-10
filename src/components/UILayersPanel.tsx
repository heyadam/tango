'use client';

// Layers tree for the design sidebar — a Figma-style outline of every node,
// grouped by screen and nested under editor-level groups, ordered TOP-OF-Z
// FIRST (the reverse of the node array, since later array index = rendered
// on top). Presentational: selection and mutation are delegated up to
// UIMockCanvas via callbacks; it portals this into UIPanel's sidebar slot.
//
// Drag model (all HTML5-draggable, all committing through ONE atomic spec
// op — moveNodeInSpec / moveGroupInSpec):
//   - Node rows drag anywhere, including ACROSS screens. Drop above/below a
//     node row adopts THAT row's group (between grouped rows → joins the
//     group, between ungrouped rows → leaves any group); dropping on a group
//     header joins at the top of the group; dropping on a screen header or
//     an empty screen lands at the top of that screen's z, ungrouped.
//   - Group headers drag as whole blocks (same screen or across screens).
//     Drops land above/below ungrouped node rows or other group blocks —
//     never inside another group (groups stay flat).

import {
  ArrowDownToLine,
  ArrowUpToLine,
  ChevronDown,
  ChevronUp,
  Folder,
  Sparkles,
  Trash2,
  Ungroup,
} from 'lucide-react';
import type { DragEvent, MouseEvent } from 'react';
import { useEffect, useRef, useState } from 'react';
import { SHAPE_ICONS } from './UIAddPalette';
import {
  buildRows,
  dropIndexFor,
  endDropIndex,
  groupDropIndexFor,
  groupEndDropIndex,
} from '@/lib/layerTree';
import type { ReorderOp } from '@/lib/uiMockOps';
import type { UINode, UIScreen } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

// Group ids are only unique PER SCREEN ('group-1' exists on every screen
// that ever grouped) — every group callback carries the owning screen id so
// a collision can never address another screen's group.
type Props = {
  screens: UIScreen[];
  selectedIds: string[];
  activeScreenId: string | null;
  onSelect: (id: string, additive: boolean) => void;
  onSelectGroup: (groupId: string, screenId: string) => void;
  onReorder: (id: string, op: ReorderOp) => void;
  onRemove: (id: string) => void;
  onMoveNode: (
    nodeId: string,
    targetIndex: number,
    group?: string | null,
    targetScreenId?: string,
  ) => void;
  onMoveGroup: (
    groupId: string,
    targetIndex: number,
    sourceScreenId: string,
    targetScreenId?: string,
  ) => void;
  onRenameGroup: (groupId: string, name: string, screenId: string) => void;
  onUngroup: (groupId: string, screenId: string) => void;
  onSelectScreen: (id: string) => void;
  onAiForScreen: (id: string) => void;
  onRemoveScreen: (id: string) => void;
};

type Dragging =
  | { kind: 'node'; nodeId: string; screenId: string }
  | { kind: 'group'; groupId: string; screenId: string };

type DropTarget = {
  screenId: string;
  // Row key the indicator renders against ('g:<id>', 's:<id>', or node id).
  rowKey: string;
  edge: 'above' | 'below' | 'into';
  // Pre-computed insertion index for the move op.
  targetIndex: number;
  // Node drops only: group to join (string) or leave (null).
  group: string | null;
};

export default function UILayersPanel({
  screens,
  selectedIds,
  activeScreenId,
  onSelect,
  onSelectGroup,
  onReorder,
  onRemove,
  onMoveNode,
  onMoveGroup,
  onRenameGroup,
  onUngroup,
  onSelectScreen,
  onAiForScreen,
  onRemoveScreen,
}: Props) {
  const selected = new Set(selectedIds);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [renaming, setRenaming] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null);
  const [dragging, setDragging] = useState<Dragging | null>(null);
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null);

  useEffect(() => {
    if (confirmingDelete === null) return;
    const timer = window.setTimeout(() => setConfirmingDelete(null), 2500);
    return () => window.clearTimeout(timer);
  }, [confirmingDelete]);

  const headerRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  useEffect(() => {
    if (!activeScreenId) return;
    headerRefs.current.get(activeScreenId)?.scrollIntoView({ block: 'nearest' });
  }, [activeScreenId]);

  const toggleCollapsed = (id: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // ── drag-to-reorder plumbing ─────────────────────────────────────────────

  // Where a drop on this row would land, or null when the row is not a valid
  // target for the current drag (drop onto itself, group into a group, …).
  const computeRowDrop = (
    e: DragEvent,
    screen: UIScreen,
    row: { rowKey: string; refNode?: UINode; groupId?: string },
  ): DropTarget | null => {
    if (!dragging) return null;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const edge: 'above' | 'below' =
      e.clientY < rect.top + rect.height / 2 ? 'above' : 'below';

    if (dragging.kind === 'node') {
      if (row.groupId !== undefined && row.refNode === undefined) {
        // Group header: join the group at the top of its block.
        const topMember = [...screen.nodes]
          .reverse()
          .find((n) => n.group === row.groupId);
        if (!topMember || topMember.id === dragging.nodeId) return null;
        return {
          screenId: screen.id,
          rowKey: row.rowKey,
          edge: 'into',
          targetIndex: dropIndexFor(screen, topMember.id, 'above', dragging.nodeId),
          group: row.groupId,
        };
      }
      const refNode = row.refNode!;
      if (refNode.id === dragging.nodeId) return null;
      return {
        screenId: screen.id,
        rowKey: row.rowKey,
        edge,
        targetIndex: dropIndexFor(screen, refNode.id, edge, dragging.nodeId),
        group: refNode.group ?? null,
      };
    }

    // Group block drag.
    if (row.refNode !== undefined) {
      // Only ungrouped node rows — a block can't interleave another group.
      if (row.refNode.group) return null;
      const idx = groupDropIndexFor(
        screen,
        row.refNode.id,
        edge,
        dragging.groupId,
        dragging.screenId,
      );
      if (idx === null) return null;
      return { screenId: screen.id, rowKey: row.rowKey, edge, targetIndex: idx, group: null };
    }
    // Another group's header: land the block above/below that block. A
    // SAME-ID group on a different screen is a different group — only the
    // dragged group's own header is excluded.
    if (
      row.groupId === undefined ||
      (row.groupId === dragging.groupId && screen.id === dragging.screenId)
    ) {
      return null;
    }
    const members = [...screen.nodes]
      .reverse()
      .filter((n) => n.group === row.groupId);
    if (members.length === 0) return null;
    const ref = edge === 'above' ? members[0] : members[members.length - 1];
    const idx = groupDropIndexFor(screen, ref.id, edge, dragging.groupId, dragging.screenId);
    if (idx === null) return null;
    return { screenId: screen.id, rowKey: row.rowKey, edge, targetIndex: idx, group: null };
  };

  const onRowDragOver = (
    e: DragEvent,
    screen: UIScreen,
    row: { rowKey: string; refNode?: UINode; groupId?: string },
  ) => {
    const target = computeRowDrop(e, screen, row);
    if (!target) {
      if (dropTarget?.rowKey === row.rowKey) setDropTarget(null);
      return;
    }
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';
    setDropTarget(target);
  };

  // Screen header / empty-screen drop: land at the top of that screen's z,
  // ungrouped — the cross-screen path for both node and group drags.
  const onScreenDragOver = (e: DragEvent, screen: UIScreen) => {
    if (!dragging) return;
    const target: DropTarget =
      dragging.kind === 'node'
        ? {
            screenId: screen.id,
            rowKey: `s:${screen.id}`,
            edge: 'into',
            targetIndex: endDropIndex(screen, dragging.nodeId),
            group: null,
          }
        : {
            screenId: screen.id,
            rowKey: `s:${screen.id}`,
            edge: 'into',
            targetIndex: groupEndDropIndex(screen, dragging.groupId, dragging.screenId),
            group: null,
          };
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    setDropTarget(target);
  };

  const commitDrop = (e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (dragging && dropTarget) {
      const cross =
        dropTarget.screenId !== dragging.screenId
          ? dropTarget.screenId
          : undefined;
      if (dragging.kind === 'node') {
        onMoveNode(dragging.nodeId, dropTarget.targetIndex, dropTarget.group, cross);
      } else {
        onMoveGroup(dragging.groupId, dropTarget.targetIndex, dragging.screenId, cross);
      }
    }
    setDragging(null);
    setDropTarget(null);
  };

  const endDrag = () => {
    setDragging(null);
    setDropTarget(null);
  };

  const dropIndicator = (rowKey: string) =>
    dropTarget?.rowKey === rowKey
      ? dropTarget.edge === 'above'
        ? 'shadow-[0_-2px_0_0_var(--color-ring)]'
        : dropTarget.edge === 'below'
          ? 'shadow-[0_2px_0_0_var(--color-ring)]'
          : 'ring-1 ring-ring'
      : undefined;

  const nodeRow = (screen: UIScreen, node: UINode, indent: boolean) => {
    const isSelected = selected.has(node.id);
    const Icon = SHAPE_ICONS[node.type];
    return (
      <div
        key={node.id}
        role="button"
        tabIndex={0}
        draggable
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = 'move';
          e.dataTransfer.setData('text/plain', node.id);
          setDragging({ kind: 'node', nodeId: node.id, screenId: screen.id });
        }}
        onDragEnd={endDrag}
        onDragOver={(e) =>
          onRowDragOver(e, screen, { rowKey: node.id, refNode: node })
        }
        onDrop={commitDrop}
        onPointerDown={(e: MouseEvent) =>
          onSelect(node.id, e.shiftKey || e.metaKey || e.ctrlKey)
        }
        className={cn(
          'group flex items-center gap-1.5 rounded-md py-1 pr-1 text-sm',
          indent ? 'pl-6' : 'pl-2',
          isSelected
            ? 'bg-accent text-foreground'
            : 'text-foreground/90 hover:bg-accent/60',
          dragging?.kind === 'node' && dragging.nodeId === node.id && 'opacity-50',
          dropIndicator(node.id),
        )}
      >
        <Icon className="size-3.5 shrink-0 text-muted-foreground" />
        <span className="min-w-0 flex-1 truncate text-xs">
          {node.text ? (
            node.text
          ) : (
            <span className="text-muted-foreground">{node.type}</span>
          )}
        </span>
        <span
          className={cn(
            'flex shrink-0 items-center opacity-0 group-hover:opacity-100',
            isSelected && 'opacity-100',
          )}
        >
          <LayerAction label="Bring to front (⌥⌘])" onClick={() => onReorder(node.id, 'front')}>
            <ArrowUpToLine className="size-3.5" />
          </LayerAction>
          <LayerAction label="Move forward (⌘])" onClick={() => onReorder(node.id, 'forward')}>
            <ChevronUp className="size-3.5" />
          </LayerAction>
          <LayerAction label="Move backward (⌘[)" onClick={() => onReorder(node.id, 'backward')}>
            <ChevronDown className="size-3.5" />
          </LayerAction>
          <LayerAction label="Send to back (⌥⌘[)" onClick={() => onReorder(node.id, 'back')}>
            <ArrowDownToLine className="size-3.5" />
          </LayerAction>
          <LayerAction label="Delete" onClick={() => onRemove(node.id)}>
            <Trash2 className="size-3.5 text-destructive" />
          </LayerAction>
        </span>
      </div>
    );
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="shrink-0 border-b border-border px-3 py-1.5 text-xs font-medium text-muted-foreground">
        Layers
      </div>
      <div className="min-h-0 flex-1 overflow-auto p-1">
        {screens.length === 0 ? (
          <p className="px-2 py-3 text-xs text-muted-foreground">No screens yet.</p>
        ) : (
          screens.map((screen) => {
            const isCollapsed = collapsed.has(screen.id);
            const isActive = screen.id === activeScreenId;
            const rows = buildRows(screen);
            return (
              <div key={screen.id} className="mb-1">
                <div
                  ref={(el) => {
                    if (el) headerRefs.current.set(screen.id, el);
                    else headerRefs.current.delete(screen.id);
                  }}
                  onDragOver={(e) => onScreenDragOver(e, screen)}
                  onDrop={commitDrop}
                  className={cn(
                    'group flex items-center gap-1 rounded-md border-l-2 px-1 transition-colors',
                    isActive
                      ? 'border-primary bg-accent/40 text-foreground'
                      : 'border-transparent text-muted-foreground/70',
                    dropIndicator(`s:${screen.id}`),
                  )}
                >
                  <button
                    type="button"
                    aria-expanded={!isCollapsed}
                    aria-label={isCollapsed ? 'Expand screen layers' : 'Collapse screen layers'}
                    onPointerDown={(e) => e.stopPropagation()}
                    onClick={() => toggleCollapsed(screen.id)}
                    className="flex size-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
                  >
                    <ChevronDown
                      className={cn('size-3.5 transition-transform', isCollapsed && '-rotate-90')}
                    />
                  </button>
                  <button
                    type="button"
                    onClick={() => onSelectScreen(screen.id)}
                    className="min-w-0 flex-1 truncate py-1 text-left text-[10px] font-semibold uppercase tracking-wide"
                  >
                    {screen.title}
                  </button>
                  <span
                    className={cn(
                      'flex shrink-0 items-center opacity-0 group-hover:opacity-100',
                      confirmingDelete === screen.id && 'opacity-100',
                    )}
                  >
                    <LayerAction
                      label="Ask AI about this screen"
                      onClick={() => onAiForScreen(screen.id)}
                    >
                      <Sparkles className="size-3.5" />
                    </LayerAction>
                    {confirmingDelete === screen.id ? (
                      <button
                        type="button"
                        onPointerDown={(e) => e.stopPropagation()}
                        onClick={(e) => {
                          e.stopPropagation();
                          setConfirmingDelete(null);
                          onRemoveScreen(screen.id);
                        }}
                        className="rounded bg-destructive px-1.5 text-[10px] text-destructive-foreground"
                      >
                        Sure?
                      </button>
                    ) : (
                      <LayerAction
                        label="Delete screen"
                        onClick={() => setConfirmingDelete(screen.id)}
                      >
                        <Trash2 className="size-3.5 text-destructive" />
                      </LayerAction>
                    )}
                  </span>
                </div>
                {isCollapsed ? null : rows.length === 0 ? (
                  <p
                    className={cn(
                      'rounded-md px-2 py-1 text-xs text-muted-foreground/60',
                      dropIndicator(`s:${screen.id}`),
                    )}
                    onDragOver={(e) => onScreenDragOver(e, screen)}
                    onDrop={commitDrop}
                  >
                    Empty
                  </p>
                ) : (
                  rows.map((row) => {
                    if (row.kind === 'node') return nodeRow(screen, row.node, false);
                    const rowKey = `g:${row.id}`;
                    const groupCollapsed = collapsed.has(rowKey);
                    const allSelected = row.members.every((m) => selected.has(m.id));
                    return (
                      <div key={rowKey}>
                        <div
                          role="button"
                          tabIndex={0}
                          draggable={renaming !== row.id}
                          onDragStart={(e) => {
                            e.dataTransfer.effectAllowed = 'move';
                            e.dataTransfer.setData('text/plain', rowKey);
                            setDragging({
                              kind: 'group',
                              groupId: row.id,
                              screenId: screen.id,
                            });
                          }}
                          onDragEnd={endDrag}
                          onDragOver={(e) =>
                            onRowDragOver(e, screen, { rowKey, groupId: row.id })
                          }
                          onDrop={commitDrop}
                          onPointerDown={(e: MouseEvent) => {
                            if (renaming === row.id) return;
                            e.stopPropagation();
                            if (e.detail >= 2) return; // double-click → rename
                            onSelectGroup(row.id, screen.id);
                          }}
                          onDoubleClick={() => setRenaming(row.id)}
                          className={cn(
                            'group flex items-center gap-1.5 rounded-md py-1 pl-2 pr-1 text-sm',
                            allSelected
                              ? 'bg-accent text-foreground'
                              : 'text-foreground/90 hover:bg-accent/60',
                            dragging?.kind === 'group' &&
                              dragging.groupId === row.id &&
                              'opacity-50',
                            dropIndicator(rowKey),
                          )}
                        >
                          <button
                            type="button"
                            aria-expanded={!groupCollapsed}
                            aria-label={groupCollapsed ? 'Expand group' : 'Collapse group'}
                            onPointerDown={(e) => e.stopPropagation()}
                            onClick={() => toggleCollapsed(rowKey)}
                            className="flex size-4 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
                          >
                            <ChevronDown
                              className={cn(
                                'size-3 transition-transform',
                                groupCollapsed && '-rotate-90',
                              )}
                            />
                          </button>
                          <Folder className="size-3.5 shrink-0 text-muted-foreground" />
                          {renaming === row.id ? (
                            <input
                              autoFocus
                              defaultValue={row.name}
                              onPointerDown={(e) => e.stopPropagation()}
                              onBlur={(e) => {
                                setRenaming(null);
                                const v = e.target.value.trim();
                                if (v && v !== row.name) {
                                  onRenameGroup(row.id, v, screen.id);
                                }
                              }}
                              onKeyDown={(e) => {
                                if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
                                if (e.key === 'Escape') {
                                  (e.target as HTMLInputElement).value = row.name;
                                  (e.target as HTMLInputElement).blur();
                                }
                              }}
                              className="min-w-0 flex-1 rounded border border-border bg-background px-1 text-xs text-foreground outline-none"
                            />
                          ) : (
                            <span
                              className="min-w-0 flex-1 truncate text-xs font-medium"
                              title="Drag to reorder · double-click to rename"
                            >
                              {row.name}
                            </span>
                          )}
                          <span
                            className={cn(
                              'flex shrink-0 items-center opacity-0 group-hover:opacity-100',
                              allSelected && 'opacity-100',
                            )}
                          >
                            <LayerAction
                              label="Ungroup"
                              onClick={() => onUngroup(row.id, screen.id)}
                            >
                              <Ungroup className="size-3.5" />
                            </LayerAction>
                          </span>
                        </div>
                        {groupCollapsed
                          ? null
                          : row.members.map((m) => nodeRow(screen, m, true))}
                      </div>
                    );
                  })
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

function LayerAction({
  label,
  onClick,
  children,
}: {
  label: string;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      // Don't let the click bubble to the row's select handler.
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => {
        e.stopPropagation();
        onClick();
      }}
      className="flex size-6 items-center justify-center rounded text-muted-foreground hover:bg-background hover:text-foreground"
    >
      {children}
    </button>
  );
}
