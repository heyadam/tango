'use client';

// Figma-style inspector for the design sidebar: position/size, opacity,
// radius, fill/stroke, typography, and per-type props for the current
// selection. Reads display values through resolveNodeStyle (the same brain
// export/preview use) and writes through the two styling channels — theme
// tokens as className swaps (classTokens), arbitrary values as inline style —
// so every edit round-trips through export and stays agent-readable.
// Presentational: all mutations flow up via onApply → applyNodePatches
// (patches computed inside the canvas's state updater, so same-tick edits
// compose instead of clobbering).

import { useEffect, useState } from 'react';
import { Ban } from 'lucide-react';
import { TOKEN_SWATCHES } from './UIShapeStyleBar';
import {
  applyFill,
  applyFillColor,
  applyFontWeight,
  applyStrokeColor,
  applyStrokeColorHex,
  applyStrokeWidth,
  applyTextAlign,
  applyTextColor,
  hasClass,
  setStyleKey,
} from '@/lib/classTokens';
import { resolveNodeStyle } from '@/lib/uiResolve';
import type { LineEnd, UINode, UINodeType } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

type Props = {
  nodes: UINode[];
  onApply: (ids: string[], fn: (node: UINode) => Partial<UINode>) => void;
};

// Which sections a node type supports. A section renders only when EVERY
// selected node supports it; per-type props need a homogeneous selection.
const FILL_TYPES = new Set<UINodeType>(['div', 'rect', 'ellipse', 'triangle', 'star', 'Button', 'Badge']);
const STROKE_TYPES = new Set<UINodeType>(['div', 'rect', 'ellipse', 'triangle', 'star', 'line', 'arrow', 'Button', 'Badge', 'Input', 'Textarea', 'Image']);
const RADIUS_TYPES = new Set<UINodeType>(['div', 'rect', 'Button', 'Badge', 'Input', 'Textarea', 'Image']);
const TEXT_CONTENT_TYPES = new Set<UINodeType>(['text', 'heading', 'Button', 'Badge']);
const PLACEHOLDER_TYPES = new Set<UINodeType>(['Input', 'Textarea']);
const TYPO_TYPES = new Set<UINodeType>(['text', 'heading', 'Button', 'Badge', 'Input', 'Textarea']);
const TEXT_COLOR_TYPES = new Set<UINodeType>(['text', 'heading', 'Button', 'Badge', 'Icon', 'Input', 'Textarea']);

const WEIGHT_OPTIONS = [
  { value: '', label: 'Default' },
  { value: 'font-normal', label: 'Regular' },
  { value: 'font-medium', label: 'Medium' },
  { value: 'font-semibold', label: 'Semibold' },
  { value: 'font-bold', label: 'Bold' },
];

const LINE_ENDS: LineEnd[] = ['n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw'];

export default function UIInspector({ nodes, onApply }: Props) {
  if (nodes.length === 0) return null;
  const first = nodes[0];
  const resolved = resolveNodeStyle(first);
  const every = (set: Set<UINodeType>) => nodes.every((n) => set.has(n.type));
  const homogeneous = nodes.every((n) => n.type === first.type);

  const apply = (fn: (node: UINode) => Partial<UINode>) => {
    onApply(nodes.map((n) => n.id), fn);
  };

  const lineLike = first.type === 'line' || first.type === 'arrow';

  return (
    <div className="flex flex-col gap-3 p-3 text-xs">
      <div className="text-[10px] text-muted-foreground">
        {nodes.length === 1
          ? first.type
          : `${nodes.length} selected${homogeneous ? ` · ${first.type}` : ''}`}
      </div>

      {/* Position & size — everything has a box. */}
      <Section label="Position">
        <div className="grid grid-cols-2 gap-1.5">
          <NumField label="X" value={first.x} onCommit={(v) => apply(() => ({ x: v }))} />
          <NumField label="Y" value={first.y} onCommit={(v) => apply(() => ({ y: v }))} />
          <NumField label="W" value={first.width} min={1} onCommit={(v) => apply(() => ({ width: Math.max(1, v) }))} />
          <NumField label="H" value={first.height} min={1} onCommit={(v) => apply(() => ({ height: Math.max(1, v) }))} />
        </div>
      </Section>

      <Section label="Appearance">
        <div className="grid grid-cols-2 gap-1.5">
          <NumField
            label="Opacity"
            value={Math.round((resolved.opacity ?? 1) * 100)}
            min={0}
            max={100}
            suffix="%"
            onCommit={(v) =>
              apply((n) =>
                setStyleKey(n, 'opacity', v >= 100 ? null : Math.max(0, v) / 100),
              )
            }
          />
          {every(RADIUS_TYPES) && (
            <NumField
              label="Radius"
              value={Math.min(resolved.cornerRadius ?? 0, 999)}
              min={0}
              onCommit={(v) => apply((n) => setStyleKey(n, 'borderRadius', v))}
            />
          )}
        </div>
      </Section>

      {every(FILL_TYPES) && (
        <Section label="Fill">
          <SwatchRow
            active={(token) => hasClass(first, `bg-${token}`)}
            onToken={(token) => apply((n) => applyFill(n, token))}
            onNone={() => apply((n) => applyFill(n, null))}
            noneActive={hasClass(first, 'bg-transparent')}
            customValue={styleString(first, 'backgroundColor')}
            onCustom={(hex) => apply((n) => applyFillColor(n, hex))}
          />
        </Section>
      )}

      {every(TEXT_COLOR_TYPES) && (
        <Section label="Color">
          <SwatchRow
            active={(token) => hasClass(first, `text-${token}`)}
            onToken={(token) => apply((n) => applyTextColor(n, token))}
            customValue={styleString(first, 'color')}
            onCustom={(hex) => apply((n) => setStyleKey(n, 'color', hex))}
          />
        </Section>
      )}

      {every(STROKE_TYPES) && (
        <Section label="Stroke">
          <SwatchRow
            active={(token) => hasClass(first, `border-${token}`)}
            onToken={(token) => apply((n) => applyStrokeColor(n, token))}
            customValue={styleString(first, 'borderColor')}
            onCustom={(hex) => apply((n) => applyStrokeColorHex(n, hex))}
          />
          <div className="mt-1.5 flex items-center gap-1">
            <span className="w-12 text-[10px] text-muted-foreground">Width</span>
            {(lineLike ? [1, 2, 4, 8] : [0, 1, 2, 4]).map((w) => (
              <button
                key={w}
                type="button"
                onClick={() => apply((n) => applyStrokeWidth(n, w))}
                className={cn(
                  'rounded px-1.5 py-0.5 font-mono text-[10px] tabular-nums text-foreground hover:bg-accent',
                  hasClass(first, `border-${w}`) && 'bg-accent ring-1 ring-ring',
                )}
              >
                {w}
              </button>
            ))}
            <button
              type="button"
              title="Dashed"
              onClick={() =>
                apply((n) => ({
                  className: hasClass(n, 'border-dashed')
                    ? (n.className ?? '')
                        .split(/\s+/)
                        .filter((c) => c && c !== 'border-dashed')
                        .join(' ') || undefined
                    : `${n.className ?? ''} border-dashed`.trim(),
                }))
              }
              className={cn(
                'ml-1 rounded px-1.5 py-0.5 text-[10px] text-foreground hover:bg-accent',
                hasClass(first, 'border-dashed') && 'bg-accent ring-1 ring-ring',
              )}
            >
              – –
            </button>
          </div>
        </Section>
      )}

      {nodes.length === 1 && TEXT_CONTENT_TYPES.has(first.type) && (
        <Section label="Text">
          <TextInput
            value={first.text ?? ''}
            onCommit={(v) => apply(() => ({ text: v }))}
          />
        </Section>
      )}

      {nodes.length === 1 && PLACEHOLDER_TYPES.has(first.type) && (
        <Section label="Placeholder">
          <TextInput
            value={
              typeof first.props?.placeholder === 'string'
                ? first.props.placeholder
                : (first.text ?? '')
            }
            onCommit={(v) =>
              apply((n) => ({ props: { ...n.props, placeholder: v } }))
            }
          />
        </Section>
      )}

      {every(TYPO_TYPES) && (
        <Section label="Typography">
          <div className="grid grid-cols-2 gap-1.5">
            <NumField
              label="Size"
              value={resolved.fontSize ?? 14}
              min={6}
              onCommit={(v) => apply((n) => setStyleKey(n, 'fontSize', v))}
            />
            <SelectField
              value={
                WEIGHT_OPTIONS.find((o) => o.value && hasClass(first, o.value))
                  ?.value ?? ''
              }
              options={WEIGHT_OPTIONS}
              onCommit={(v) => apply((n) => applyFontWeight(n, v || null))}
            />
          </div>
          <div className="mt-1.5 flex items-center gap-1">
            <span className="w-12 text-[10px] text-muted-foreground">Align</span>
            {(['left', 'center', 'right'] as const).map((a) => (
              <button
                key={a}
                type="button"
                onClick={() => apply((n) => applyTextAlign(n, a))}
                className={cn(
                  'rounded px-1.5 py-0.5 text-[10px] capitalize text-foreground hover:bg-accent',
                  hasClass(first, `text-${a}`) && 'bg-accent ring-1 ring-ring',
                )}
              >
                {a}
              </button>
            ))}
          </div>
        </Section>
      )}

      {homogeneous && <TypeProps node={first} apply={apply} />}
    </div>
  );
}

// Per-type props (homogeneous selections only).
function TypeProps({
  node,
  apply,
}: {
  node: UINode;
  apply: (fn: (n: UINode) => Partial<UINode>) => void;
}) {
  switch (node.type) {
    case 'heading':
      return (
        <Section label="Level">
          <div className="flex gap-1">
            {([1, 2, 3] as const).map((l) => (
              <button
                key={l}
                type="button"
                onClick={() => apply((n) => ({ props: { ...n.props, level: l } }))}
                className={cn(
                  'rounded px-2 py-0.5 font-mono text-[10px] text-foreground hover:bg-accent',
                  (node.props?.level ?? 2) === l && 'bg-accent ring-1 ring-ring',
                )}
              >
                H{l}
              </button>
            ))}
          </div>
        </Section>
      );
    case 'Button':
      return (
        <Section label="Variant">
          <SelectField
            value={typeof node.props?.variant === 'string' ? node.props.variant : 'default'}
            options={['default', 'secondary', 'outline', 'ghost', 'destructive', 'link'].map(
              (v) => ({ value: v, label: v }),
            )}
            onCommit={(v) => apply((n) => ({ props: { ...n.props, variant: v } }))}
          />
        </Section>
      );
    case 'Badge':
      return (
        <Section label="Variant">
          <SelectField
            value={typeof node.props?.variant === 'string' ? node.props.variant : 'default'}
            options={['default', 'secondary', 'destructive', 'outline'].map((v) => ({
              value: v,
              label: v,
            }))}
            onCommit={(v) => apply((n) => ({ props: { ...n.props, variant: v } }))}
          />
        </Section>
      );
    case 'Icon':
      return (
        <Section label="Icon">
          <TextInput
            value={typeof node.props?.iconName === 'string' ? node.props.iconName : ''}
            placeholder="lucide name, e.g. Search"
            onCommit={(v) => apply((n) => ({ props: { ...n.props, iconName: v } }))}
          />
        </Section>
      );
    case 'Image':
      return (
        <Section label="Source">
          <TextInput
            value={typeof node.props?.src === 'string' ? node.props.src : ''}
            placeholder="https://…"
            onCommit={(v) =>
              apply((n) => ({
                props: v ? { ...n.props, src: v } : { ...n.props, src: undefined },
              }))
            }
          />
        </Section>
      );
    case 'line':
    case 'arrow':
      return (
        <Section label="Direction">
          <div className="flex flex-wrap gap-1">
            {LINE_ENDS.map((d) => (
              <button
                key={d}
                type="button"
                onClick={() => apply((n) => ({ props: { ...n.props, end: d } }))}
                className={cn(
                  'rounded px-1.5 py-0.5 font-mono text-[10px] uppercase text-foreground hover:bg-accent',
                  (node.props?.end ?? 'e') === d && 'bg-accent ring-1 ring-ring',
                )}
              >
                {d}
              </button>
            ))}
          </div>
        </Section>
      );
    case 'star':
      return (
        <Section label="Points">
          <NumField
            label="N"
            value={typeof node.props?.points === 'number' ? node.props.points : 5}
            min={3}
            max={12}
            onCommit={(v) =>
              apply((n) => ({
                props: { ...n.props, points: Math.min(12, Math.max(3, v)) },
              }))
            }
          />
        </Section>
      );
    default:
      return null;
  }
}

// ── field primitives ────────────────────────────────────────────────────────

function Section({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="mb-1 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </div>
      {children}
    </div>
  );
}

// Number input committing on Enter/blur; re-seeds when the node value changes
// under it (drag on canvas, agent edit).
function NumField({
  label,
  value,
  onCommit,
  min,
  max,
  suffix,
}: {
  label: string;
  value: number;
  onCommit: (v: number) => void;
  min?: number;
  max?: number;
  suffix?: string;
}) {
  const rounded = Math.round(value * 100) / 100;
  const [text, setText] = useState(String(rounded));
  useEffect(() => {
    setText(String(rounded));
  }, [rounded]);
  const commit = () => {
    const n = Number(text);
    if (!Number.isFinite(n)) {
      setText(String(rounded));
      return;
    }
    const clamped = Math.min(max ?? Infinity, Math.max(min ?? -Infinity, n));
    if (clamped !== rounded) onCommit(clamped);
    setText(String(clamped));
  };
  return (
    <label className="flex items-center gap-1 rounded-md border border-border bg-background px-1.5 py-1">
      <span className="w-8 shrink-0 text-[10px] text-muted-foreground">{label}</span>
      <input
        type="number"
        value={text}
        min={min}
        max={max}
        onChange={(e) => setText(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            commit();
            (e.target as HTMLInputElement).blur();
          }
        }}
        className="w-full min-w-0 bg-transparent text-xs tabular-nums text-foreground outline-none [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
      />
      {suffix ? (
        <span className="text-[10px] text-muted-foreground">{suffix}</span>
      ) : null}
    </label>
  );
}

function TextInput({
  value,
  onCommit,
  placeholder,
}: {
  value: string;
  onCommit: (v: string) => void;
  placeholder?: string;
}) {
  const [text, setText] = useState(value);
  useEffect(() => {
    setText(value);
  }, [value]);
  return (
    <textarea
      value={text}
      placeholder={placeholder}
      rows={Math.min(4, Math.max(1, text.split('\n').length))}
      onChange={(e) => setText(e.target.value)}
      onBlur={() => {
        if (text !== value) onCommit(text);
      }}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          if (text !== value) onCommit(text);
          (e.target as HTMLTextAreaElement).blur();
        }
        if (e.key === 'Escape') {
          setText(value);
          (e.target as HTMLTextAreaElement).blur();
        }
      }}
      className="w-full resize-none rounded-md border border-border bg-background px-1.5 py-1 text-xs text-foreground outline-none focus:ring-1 focus:ring-ring"
    />
  );
}

function SelectField({
  label,
  value,
  options,
  onCommit,
}: {
  label?: string;
  value: string;
  options: Array<{ value: string; label: string }>;
  onCommit: (v: string) => void;
}) {
  return (
    <label className="flex items-center gap-1 rounded-md border border-border bg-background px-1.5 py-1">
      {label ? (
        <span className="w-8 shrink-0 text-[10px] text-muted-foreground">{label}</span>
      ) : null}
      <select
        value={value}
        onChange={(e) => onCommit(e.target.value)}
        className="w-full min-w-0 bg-transparent text-xs text-foreground outline-none"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

function SwatchRow({
  active,
  onToken,
  onNone,
  noneActive,
  customValue,
  onCustom,
}: {
  active: (token: string) => boolean;
  onToken: (token: string) => void;
  onNone?: () => void;
  noneActive?: boolean;
  customValue?: string;
  onCustom?: (hex: string) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-1">
      {TOKEN_SWATCHES.map(({ token, cls }) => (
        <button
          key={token}
          type="button"
          title={token}
          onClick={() => onToken(token)}
          className={cn(
            'size-4 rounded-full border border-border/60 transition hover:scale-110',
            cls,
            active(token) && 'ring-2 ring-ring',
          )}
        />
      ))}
      {onNone ? (
        <button
          type="button"
          title="None"
          onClick={onNone}
          className={cn(
            'flex size-4 items-center justify-center rounded-full border border-border text-muted-foreground',
            noneActive && 'ring-2 ring-ring',
          )}
        >
          <Ban className="size-3" />
        </button>
      ) : null}
      {onCustom ? (
        <input
          type="color"
          title="Custom color"
          // Seed from the node's inline value when it looks like a hex.
          value={/^#[0-9a-fA-F]{6}$/.test(customValue ?? '') ? customValue : '#888888'}
          onChange={(e) => onCustom(e.target.value)}
          className="ml-0.5 size-5 cursor-pointer rounded border border-border bg-transparent p-0"
        />
      ) : null}
    </div>
  );
}

function styleString(node: UINode, key: string): string | undefined {
  const v = node.style?.[key];
  return typeof v === 'string' ? v : undefined;
}
