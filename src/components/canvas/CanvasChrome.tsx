'use client';

// The canvas's floating chrome, extracted from UIMockCanvas: the shape draw
// toolbar, the zoom readout, the screen title-row provenance chip, and the
// empty state. All presentational — state and behavior stay in the canvas.

import { useEffect, useRef, useState } from 'react';
import { Check, Maximize, Minus, Plus, RefreshCw } from 'lucide-react';
import { Button } from '../ui/button';
import { SHAPE_ICONS } from '../UIAddPalette';
import { NODE_LABELS, SHAPE_TYPE_ORDER } from '@/lib/uiMockDefaults';
import { MAX_ZOOM, MIN_ZOOM } from '@/lib/uiCanvasCamera';
import type { SourceSyncStatus, UINodeType } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

// Provenance chip in the screen title row: '↕ <basename>' when the screen is
// linked to a Swift source (import reads it, Export & Run writes the View's
// body back in place), else '↑ <TypeName>.swift' (the file Export & Run will
// create). Click copies the relevant workspace-relative path. When the
// source-sync watcher reports the linked file changed since import, the chip
// goes warning-tinted ('stale'); a deleted source reads 'missing'.
// Renders inside the transformed title row, so it scales with zoom — accepted
// (informational only; all triggers live in screen space).
export function ScreenFileChip({
  sourceFile,
  exportName,
  syncStatus,
}: {
  sourceFile?: string;
  exportName: string;
  syncStatus?: SourceSyncStatus;
}) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<number | null>(null);
  useEffect(() => {
    return () => {
      if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    };
  }, []);

  const syncNote =
    syncStatus === 'stale'
      ? '\n⚠ code changed since import — refresh to re-import'
      : syncStatus === 'missing'
        ? '\n⚠ source file is missing'
        : '';

  return (
    <button
      type="button"
      className={cn(
        'ml-2 inline-flex max-w-40 items-center gap-0.5 truncate align-bottom font-mono text-[10px]',
        syncStatus === 'stale'
          ? 'text-warning-foreground'
          : syncStatus === 'missing'
            ? 'text-destructive/80 line-through'
            : 'text-muted-foreground hover:text-foreground',
      )}
      title={
        sourceFile
          ? `Linked to ${sourceFile}\nImport reads it; Export & Run rewrites the View's body in place.${syncNote}`
          : `No source file yet — Export & Run creates a file like ${exportName} at the app source root (final name avoids the project's existing types).`
      }
      // Keep the copy click from also activating the screen via the row.
      onPointerDown={(e) => e.stopPropagation()}
      onClick={() => {
        void navigator.clipboard.writeText(sourceFile ?? exportName);
        setCopied(true);
        if (timerRef.current !== null) window.clearTimeout(timerRef.current);
        timerRef.current = window.setTimeout(() => setCopied(false), 1200);
      }}
    >
      {syncStatus === 'stale' && (
        <span
          aria-hidden
          className="mr-0.5 inline-block size-1.5 shrink-0 animate-pulse rounded-full bg-warning"
        />
      )}
      {copied ? (
        <>
          <Check className="size-3" />
          copied
        </>
      ) : sourceFile ? (
        `↕ ${basename(sourceFile)}`
      ) : (
        `↑ ${exportName}`
      )}
    </button>
  );
}

// Title-row refresh action for linked screens: re-import this screen from its
// source file (a scoped fast-import run). Quiet when in sync, warning-tinted
// and always-visible when the source changed underneath the canvas.
export function ScreenRefreshButton({
  screenId,
  sourceFile,
  syncStatus,
  onReimport,
}: {
  screenId: string;
  sourceFile: string;
  syncStatus?: SourceSyncStatus;
  onReimport: (screenId: string, sourceFile: string) => void;
}) {
  if (syncStatus === 'missing') return null;
  return (
    <button
      type="button"
      aria-label={`Re-import ${screenId} from ${sourceFile}`}
      title={
        syncStatus === 'stale'
          ? `${sourceFile} changed since import — click to re-import this screen`
          : `Re-import this screen from ${sourceFile}`
      }
      onPointerDown={(e) => e.stopPropagation()}
      onClick={() => onReimport(screenId, sourceFile)}
      className={cn(
        'ml-1 inline-flex size-4 items-center justify-center rounded align-bottom',
        syncStatus === 'stale'
          ? 'text-warning-foreground hover:bg-warning/20'
          : 'text-muted-foreground/60 hover:bg-accent hover:text-foreground',
      )}
    >
      <RefreshCw className="size-3" />
    </button>
  );
}

function basename(path: string): string {
  const i = path.lastIndexOf('/');
  return i === -1 ? path : path.slice(i + 1);
}

// Shape draw tools: click (or R/O/L) to arm, click again or Escape to disarm.
// Armed state mounts the crosshair overlay in the canvas; committing a draw
// disarms back to select (one-shot, like Figma).
const SHAPE_SHORTCUTS: Partial<Record<UINodeType, string>> = {
  rect: 'R',
  ellipse: 'O',
  line: 'L',
  arrow: '⇧L',
};

export function ShapeToolbar({
  tool,
  disabled,
  onArm,
}: {
  tool: UINodeType | null;
  disabled: boolean;
  onArm: (type: UINodeType) => void;
}) {
  return (
    <div className="flex items-center gap-0.5 rounded-md bg-secondary p-0.5 text-secondary-foreground shadow-md">
      {SHAPE_TYPE_ORDER.map((type) => {
        const Icon = SHAPE_ICONS[type];
        const shortcut = SHAPE_SHORTCUTS[type];
        return (
          <Button
            key={type}
            size="sm"
            variant="ghost"
            disabled={disabled}
            className={cn(
              'size-7 px-0',
              tool === type &&
                'bg-primary text-primary-foreground hover:bg-primary hover:text-primary-foreground',
            )}
            onClick={() => onArm(type)}
            title={`${NODE_LABELS[type]}${shortcut ? ` (${shortcut})` : ''}`}
            aria-pressed={tool === type}
          >
            <Icon className="size-3.5" />
          </Button>
        );
      })}
    </div>
  );
}

// Figma-style zoom readout: −/+ step around the viewport center, clicking
// the percentage resets to 100%, Fit reframes the whole spec.
export function ZoomControls({
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

export function EmptyState() {
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
