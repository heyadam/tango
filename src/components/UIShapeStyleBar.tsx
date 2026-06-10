'use client';

// Compact style controls shown while the selection is shape nodes: fill and
// stroke swatches over the theme tokens, stroke width, and corner radius for
// rectangles. Every edit is a className token swap (classTokens.ts) — the
// same vocabulary the agent and the resolver use — applied through the
// canvas's normal updateNodes flow, so swatch clicks ride the snapshot wire
// like any drag. Presentational: parent decides when to mount it.

import { Ban } from 'lucide-react';
import { isLineTool } from '@/lib/shapeDraw';
import {
  applyFill,
  applyRadius,
  applyStrokeColor,
  applyStrokeWidth,
  hasClass,
} from '@/lib/classTokens';
import type { UINode } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

type Props = {
  nodes: UINode[];
  onApply: (patches: Map<string, Partial<UINode>>) => void;
};

// Literal class strings so the Tailwind JIT sees every swatch color. Shared
// with the sidebar inspector (UIInspector) — one swatch vocabulary everywhere.
export const TOKEN_SWATCHES: Array<{ token: string; cls: string }> = [
  { token: 'primary', cls: 'bg-primary' },
  { token: 'secondary', cls: 'bg-secondary' },
  { token: 'accent', cls: 'bg-accent' },
  { token: 'destructive', cls: 'bg-destructive' },
  { token: 'warning', cls: 'bg-warning' },
  { token: 'muted', cls: 'bg-muted' },
  { token: 'foreground', cls: 'bg-foreground' },
  { token: 'background', cls: 'bg-background' },
];
const SWATCHES = TOKEN_SWATCHES;

const RADII: Array<{ cls: string | null; label: string }> = [
  { cls: 'rounded-none', label: '0' },
  { cls: 'rounded-md', label: '8' },
  { cls: 'rounded-xl', label: '14' },
  { cls: 'rounded-full', label: '●' },
];

export default function UIShapeStyleBar({ nodes, onApply }: Props) {
  if (nodes.length === 0) return null;
  const first = nodes[0];
  const allLines = nodes.every((n) => isLineTool(n.type));
  const allRects = nodes.every((n) => n.type === 'rect');
  const widths = allLines ? [1, 2, 4] : [0, 1, 2, 4];

  const apply = (fn: (node: UINode) => Partial<UINode>) => {
    const patches = new Map<string, Partial<UINode>>();
    for (const n of nodes) patches.set(n.id, fn(n));
    onApply(patches);
  };

  return (
    <div
      // Keep clicks out of the canvas (selection clear / draw overlay).
      onPointerDown={(e) => e.stopPropagation()}
      className="flex flex-col gap-1.5 rounded-lg border border-border bg-card px-3 py-2 shadow-lg"
    >
      {!allLines && (
        <ControlRow label="Fill">
          {SWATCHES.map(({ token, cls }) => (
            <Swatch
              key={token}
              cls={cls}
              title={token}
              active={hasClass(first, `bg-${token}`)}
              onClick={() => apply((n) => applyFill(n, token))}
            />
          ))}
          <button
            type="button"
            title="No fill"
            onClick={() => apply((n) => applyFill(n, null))}
            className={cn(
              'flex size-4 items-center justify-center rounded-full border border-border text-muted-foreground',
              hasClass(first, 'bg-transparent') && 'ring-2 ring-ring',
            )}
          >
            <Ban className="size-3" />
          </button>
        </ControlRow>
      )}
      <ControlRow label="Stroke">
        {SWATCHES.map(({ token, cls }) => (
          <Swatch
            key={token}
            cls={cls}
            title={token}
            active={hasClass(first, `border-${token}`)}
            onClick={() => apply((n) => applyStrokeColor(n, token))}
          />
        ))}
        <span className="mx-1 h-4 w-px bg-border" />
        {widths.map((w) => (
          <button
            key={w}
            type="button"
            title={w === 0 ? 'No stroke' : `${w}px`}
            onClick={() => apply((n) => applyStrokeWidth(n, w))}
            className={cn(
              'rounded px-1 font-mono text-[10px] tabular-nums text-foreground hover:bg-accent',
              hasClass(first, `border-${w}`) && 'bg-accent ring-1 ring-ring',
            )}
          >
            {w}
          </button>
        ))}
      </ControlRow>
      {allRects && (
        <ControlRow label="Radius">
          {RADII.map(({ cls, label }) => (
            <button
              key={label}
              type="button"
              title={cls ?? 'default'}
              onClick={() => apply((n) => applyRadius(n, cls))}
              className={cn(
                'rounded px-1 font-mono text-[10px] tabular-nums text-foreground hover:bg-accent',
                cls && hasClass(first, cls) && 'bg-accent ring-1 ring-ring',
              )}
            >
              {label}
            </button>
          ))}
        </ControlRow>
      )}
    </div>
  );
}

function ControlRow({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center gap-1">
      <span className="w-10 text-[10px] font-medium text-muted-foreground">
        {label}
      </span>
      {children}
    </div>
  );
}

function Swatch({
  cls,
  title,
  active,
  onClick,
}: {
  cls: string;
  title: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className={cn(
        'size-4 rounded-full border border-border/60 transition hover:scale-110',
        cls,
        active && 'ring-2 ring-ring',
      )}
    />
  );
}
