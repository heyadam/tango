'use client';

// Floating layers panel for UI mode — a Figma-style list of every node,
// grouped by screen, ordered TOP-OF-Z FIRST (the reverse of the node array,
// since later array index = rendered on top). Presentational: selection and
// mutation are delegated up to UIMockCanvas via callbacks. Lives as an overlay
// inside UIMockCanvas because that's where the spec/selection state lives.

import {
  ArrowDownToLine,
  ArrowUpToLine,
  ChevronDown,
  ChevronUp,
  Sparkles,
  Trash2,
  X,
} from 'lucide-react';
import type { MouseEvent } from 'react';
import { useEffect, useRef, useState } from 'react';
import { Button } from './ui/button';
import type { ReorderOp } from '@/lib/uiMockOps';
import type { UIScreen } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

type Props = {
  screens: UIScreen[];
  selectedIds: string[];
  activeScreenId: string | null;
  onSelect: (id: string, additive: boolean) => void;
  onReorder: (id: string, op: ReorderOp) => void;
  onRemove: (id: string) => void;
  onSelectScreen: (id: string) => void;
  onAiForScreen: (id: string) => void;
  onRemoveScreen: (id: string) => void;
  onClose: () => void;
};

export default function UILayersPanel({
  screens,
  selectedIds,
  activeScreenId,
  onSelect,
  onReorder,
  onRemove,
  onSelectScreen,
  onAiForScreen,
  onRemoveScreen,
  onClose,
}: Props) {
  const selected = new Set(selectedIds);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  // Two-step screen delete: first click arms 'Sure?' for 2.5s (screens are
  // the most expensive artifact and there's no undo), second click removes.
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(
    null,
  );
  useEffect(() => {
    if (confirmingDelete === null) return;
    const timer = window.setTimeout(() => setConfirmingDelete(null), 2500);
    return () => window.clearTimeout(timer);
  }, [confirmingDelete]);

  // Header elements keyed by screen id, for scrollIntoView on activation.
  const headerRefs = useRef<Map<string, HTMLDivElement>>(new Map());
  useEffect(() => {
    if (!activeScreenId) return;
    headerRefs.current
      .get(activeScreenId)
      ?.scrollIntoView({ block: 'nearest' });
  }, [activeScreenId]);

  const toggleCollapsed = (id: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };
  return (
    <div
      onPointerDown={(e) => e.stopPropagation()}
      className="flex max-h-full w-60 flex-col rounded-lg border border-border bg-card shadow-lg"
    >
      <div className="flex shrink-0 items-center justify-between border-b border-border px-2 py-1.5">
        <span className="text-xs font-medium text-muted-foreground">Layers</span>
        <Button
          variant="ghost"
          size="icon"
          className="size-6 text-muted-foreground hover:bg-accent"
          onClick={onClose}
          aria-label="Close layers panel"
        >
          <X className="size-3.5" />
        </Button>
      </div>

      <div className="min-h-0 flex-1 overflow-auto p-1">
        {screens.length === 0 ? (
          <p className="px-2 py-3 text-xs text-muted-foreground">
            No screens yet.
          </p>
        ) : (
          screens.map((screen) => {
            const isCollapsed = collapsed.has(screen.id);
            const isActive = screen.id === activeScreenId;
            return (
            <div key={screen.id} className="mb-1">
              <div
                ref={(el) => {
                  if (el) headerRefs.current.set(screen.id, el);
                  else headerRefs.current.delete(screen.id);
                }}
                className={cn(
                  'group flex items-center gap-1 rounded-md border-l-2 px-1 transition-colors',
                  isActive
                    ? 'border-primary bg-accent/40 text-foreground'
                    : 'border-transparent text-muted-foreground/70',
                )}
              >
                <button
                  type="button"
                  aria-expanded={!isCollapsed}
                  aria-label={
                    isCollapsed ? 'Expand screen layers' : 'Collapse screen layers'
                  }
                  onPointerDown={(e) => e.stopPropagation()}
                  onClick={() => toggleCollapsed(screen.id)}
                  className="flex size-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:text-foreground"
                >
                  <ChevronDown
                    className={cn(
                      'size-3.5 transition-transform',
                      isCollapsed && '-rotate-90',
                    )}
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
              {screen.sourceFile ? (
                <div
                  className="truncate px-2 pb-0.5 font-mono text-[10px] text-muted-foreground/60"
                  title={screen.sourceFile}
                >
                  {screen.sourceFile}
                </div>
              ) : null}
              {isCollapsed ? null : screen.nodes.length === 0 ? (
                <p className="px-2 py-1 text-xs text-muted-foreground/60">
                  Empty
                </p>
              ) : (
                // Reverse so the top-of-z node sits at the top of the list.
                [...screen.nodes].reverse().map((node) => {
                  const isSelected = selected.has(node.id);
                  return (
                    <div
                      key={node.id}
                      role="button"
                      tabIndex={0}
                      onPointerDown={(e: MouseEvent) =>
                        onSelect(node.id, e.shiftKey || e.metaKey || e.ctrlKey)
                      }
                      className={cn(
                        'group flex items-center gap-1 rounded-md px-2 py-1 text-sm',
                        isSelected
                          ? 'bg-accent text-foreground'
                          : 'text-foreground/90 hover:bg-accent/60',
                      )}
                    >
                      <span className="min-w-0 flex-1 truncate">
                        <span className="font-mono text-[11px] text-muted-foreground">
                          {node.type}
                        </span>
                        {node.text ? (
                          <span className="ml-1.5 truncate">{node.text}</span>
                        ) : null}
                      </span>
                      <span
                        className={cn(
                          'flex shrink-0 items-center opacity-0 group-hover:opacity-100',
                          isSelected && 'opacity-100',
                        )}
                      >
                        <LayerAction
                          label="Bring to front"
                          onClick={() => onReorder(node.id, 'front')}
                        >
                          <ArrowUpToLine className="size-3.5" />
                        </LayerAction>
                        <LayerAction
                          label="Move forward"
                          onClick={() => onReorder(node.id, 'forward')}
                        >
                          <ChevronUp className="size-3.5" />
                        </LayerAction>
                        <LayerAction
                          label="Move backward"
                          onClick={() => onReorder(node.id, 'backward')}
                        >
                          <ChevronDown className="size-3.5" />
                        </LayerAction>
                        <LayerAction
                          label="Send to back"
                          onClick={() => onReorder(node.id, 'back')}
                        >
                          <ArrowDownToLine className="size-3.5" />
                        </LayerAction>
                        <LayerAction
                          label="Delete"
                          onClick={() => onRemove(node.id)}
                        >
                          <Trash2 className="size-3.5 text-destructive" />
                        </LayerAction>
                      </span>
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
