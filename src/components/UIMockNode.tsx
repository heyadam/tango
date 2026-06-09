'use client';

// Renders a single UINode by `type` to its corresponding shadcn primitive (or
// a layout primitive for `div` / `text` / `heading` / `Image`). Every node
// fills its bounding box with `w-full h-full` so the wrapper's absolute
// positioning is the single source of truth for size — drag/resize math in
// the canvas writes back to the node's x/y/width/height, never touches inner
// styling. The node's optional `className` rides on top via tailwind-merge,
// and `style` is applied inline on the same element so off-theme colors that
// can't be expressed as Tailwind classes (the JIT can't see runtime strings)
// still render faithfully.

import {
  type CSSProperties,
  type ReactNode,
  memo,
  useEffect,
  useRef,
} from 'react';
import * as Lucide from 'lucide-react';
import { Badge } from './ui/badge';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Separator } from './ui/separator';
import { Textarea } from './ui/textarea';
import { cn } from '@/lib/utils';
import type { UINode } from '@/lib/uiMockProtocol';

// Layout-affecting CSS keys the renderer drops from `node.style`. Coords are
// the source of truth for layout (same policy as `className` ignoring
// `flex`/`grid`/`w-*`/`h-*`), so anything that would push the node away from
// its absolute box gets stripped before reaching React.
const LAYOUT_STYLE_KEYS = new Set([
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'inset',
  'insetBlock',
  'insetBlockEnd',
  'insetBlockStart',
  'insetInline',
  'insetInlineEnd',
  'insetInlineStart',
  'width',
  'minWidth',
  'maxWidth',
  'height',
  'minHeight',
  'maxHeight',
  'transform',
  'translate',
  'rotate',
  'scale',
  'display',
  'float',
  'clear',
  'flex',
  'flexBasis',
  'flexDirection',
  'flexFlow',
  'flexGrow',
  'flexShrink',
  'flexWrap',
  'grid',
  'gridArea',
  'gridAutoColumns',
  'gridAutoFlow',
  'gridAutoRows',
  'gridColumn',
  'gridColumnEnd',
  'gridColumnStart',
  'gridRow',
  'gridRowEnd',
  'gridRowStart',
  'gridTemplate',
  'gridTemplateAreas',
  'gridTemplateColumns',
  'gridTemplateRows',
]);

export function sanitizeNodeStyle(
  style: UINode['style'],
): CSSProperties | undefined {
  if (!style) return undefined;
  const out: Record<string, string | number> = {};
  let kept = 0;
  for (const [key, value] of Object.entries(style)) {
    if (LAYOUT_STYLE_KEYS.has(key)) continue;
    if (value === null || value === undefined) continue;
    out[key] = value;
    kept += 1;
  }
  if (kept === 0) return undefined;
  return out as CSSProperties;
}

type Props = {
  node: UINode;
  isEditing: boolean;
  onCommitText: (text: string) => void;
  onEndEdit: () => void;
};

// Memoized: parent re-renders (drag frames, selection changes) skip nodes
// whose props are identity-equal — uiMockOps preserves untouched node refs.
export default memo(function UIMockNode({
  node,
  isEditing,
  onCommitText,
  onEndEdit,
}: Props) {
  // Inline-style overrides land on the same element that gets `node.className`,
  // so they win over both shadcn variants and theme-token Tailwind. This is
  // the channel for off-theme colors / gradients / custom shadows that
  // arbitrary-value Tailwind classes can't carry from runtime JSON.
  const style = sanitizeNodeStyle(node.style);

  switch (node.type) {
    case 'div':
      return (
        <div
          className={cn(
            'h-full w-full rounded-md border border-dashed border-border/60 bg-muted/30',
            node.className,
          )}
          style={style}
        />
      );

    case 'text':
      return (
        <Editable
          isEditing={isEditing}
          value={node.text ?? ''}
          onCommit={onCommitText}
          onEnd={onEndEdit}
          // `whitespace-pre-wrap` so newlines from edit-mode round-trip into
          // the rendered display; without it, the contentEditable value
          // would visually collapse to one line.
          className={cn(
            'h-full w-full overflow-hidden whitespace-pre-wrap text-sm leading-tight text-foreground',
            node.className,
          )}
          style={style}
        />
      );

    case 'heading': {
      const level = pickHeadingLevel(node.props?.level);
      const fontSize =
        level === 1
          ? 'text-3xl font-bold'
          : level === 2
            ? 'text-2xl font-semibold'
            : 'text-lg font-semibold';
      return (
        <Editable
          isEditing={isEditing}
          value={node.text ?? ''}
          onCommit={onCommitText}
          onEnd={onEndEdit}
          className={cn(
            'h-full w-full overflow-hidden whitespace-pre-wrap font-serif tracking-tight text-foreground',
            fontSize,
            node.className,
          )}
          style={style}
        />
      );
    }

    case 'Button': {
      const variant = pickButtonVariant(node.props?.variant);
      // We let the absolute box drive size — `h-full w-full` overrides the
      // size-variant heights so the user's resize is faithful. Tailwind-merge
      // (via cn) keeps this from fighting buttonVariants() ordering.
      return (
        <Button
          variant={variant}
          // The mock is non-interactive; tabIndex -1 keeps focus out so the
          // canvas's selection/drag isn't fighting button focus rings.
          tabIndex={-1}
          className={cn(
            'h-full w-full px-3',
            isEditing && 'pointer-events-none',
            node.className,
          )}
          style={style}
        >
          {isEditing ? (
            <Editable
              isEditing
              value={node.text ?? ''}
              onCommit={onCommitText}
              onEnd={onEndEdit}
              className="bg-transparent text-inherit"
            />
          ) : (
            (node.text ?? 'Button')
          )}
        </Button>
      );
    }

    case 'Input': {
      const placeholder =
        typeof node.props?.placeholder === 'string'
          ? node.props.placeholder
          : (node.text ?? 'Placeholder');
      return (
        <Input
          placeholder={placeholder}
          // Read-only: it's a mock, not a working form. Otherwise focus
          // stealing fights canvas selection.
          readOnly
          tabIndex={-1}
          className={cn('h-full w-full', node.className)}
          style={style}
        />
      );
    }

    case 'Textarea': {
      const placeholder =
        typeof node.props?.placeholder === 'string'
          ? node.props.placeholder
          : (node.text ?? 'Placeholder');
      return (
        <Textarea
          placeholder={placeholder}
          readOnly
          tabIndex={-1}
          className={cn('h-full w-full resize-none', node.className)}
          style={style}
        />
      );
    }

    case 'Badge': {
      const variant = pickBadgeVariant(node.props?.variant);
      return (
        <div className="flex h-full w-full items-center justify-center">
          <Badge variant={variant} className={cn(node.className)} style={style}>
            {isEditing ? (
              <Editable
                isEditing
                value={node.text ?? ''}
                onCommit={onCommitText}
                onEnd={onEndEdit}
                className="bg-transparent text-inherit"
              />
            ) : (
              (node.text ?? 'Badge')
            )}
          </Badge>
        </div>
      );
    }

    case 'Separator': {
      const orientation =
        node.props?.orientation === 'vertical' ? 'vertical' : 'horizontal';
      return (
        <div className="flex h-full w-full items-center justify-center">
          <Separator
            orientation={orientation}
            className={cn(node.className)}
            style={style}
          />
        </div>
      );
    }

    case 'Image': {
      const src = typeof node.props?.src === 'string' ? node.props.src : null;
      if (src) {
        return (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={src}
            alt={node.text ?? ''}
            draggable={false}
            className={cn(
              'h-full w-full rounded-md object-cover',
              node.className,
            )}
            style={style}
          />
        );
      }
      // Placeholder: bordered box with a subtle "X" so it reads as "image
      // goes here" in the rendered mock.
      return (
        <div
          className={cn(
            'flex h-full w-full items-center justify-center rounded-md border border-dashed border-border bg-muted/40 text-muted-foreground',
            node.className,
          )}
          style={style}
          aria-label="Image placeholder"
        >
          <Lucide.ImageIcon className="size-6" />
        </div>
      );
    }

    case 'Icon': {
      const Icon = pickLucideIcon(node.props?.iconName);
      return (
        <div className="flex h-full w-full items-center justify-center">
          <Icon
            className={cn('size-full text-foreground', node.className)}
            style={style}
          />
        </div>
      );
    }

    default:
      return null;
  }
});

function Editable({
  isEditing,
  value,
  onCommit,
  onEnd,
  className,
  style,
}: {
  isEditing: boolean;
  value: string;
  onCommit: (text: string) => void;
  onEnd: () => void;
  className?: string;
  style?: CSSProperties;
}): ReactNode {
  const ref = useRef<HTMLDivElement | null>(null);
  // Track whether Enter or Escape already settled this edit, so the trailing
  // blur (which fires on unmount in some browsers) doesn't re-commit or
  // resurrect a discarded edit.
  const settled = useRef(false);

  // When edit mode starts, seed the contentEditable with the current value
  // and select-all so the user can overwrite. Intentionally NOT depending on
  // `value` — re-running on prop change would clobber whatever the user has
  // typed since edit-start. The seed is captured once per edit session.
  useEffect(() => {
    if (!isEditing) return;
    settled.current = false;
    const el = ref.current;
    if (!el) return;
    el.textContent = value;
    el.focus();
    const range = document.createRange();
    range.selectNodeContents(el);
    const sel = window.getSelection();
    if (sel) {
      sel.removeAllRanges();
      sel.addRange(range);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isEditing]);

  if (!isEditing) {
    return (
      <div className={className} style={style}>
        {value}
      </div>
    );
  }

  return (
    <div
      ref={ref}
      contentEditable
      suppressContentEditableWarning
      style={style}
      // Stop pointerdown from bubbling up to react-moveable so clicks land
      // inside the editor instead of starting a drag.
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          settled.current = true;
          const next = (e.currentTarget.textContent ?? '').trim();
          onCommit(next);
          onEnd();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          // Discard: mark settled so the trailing blur doesn't commit.
          settled.current = true;
          onEnd();
        }
      }}
      onBlur={(e) => {
        if (settled.current) return;
        settled.current = true;
        const next = (e.currentTarget.textContent ?? '').trim();
        onCommit(next);
        onEnd();
      }}
      className={cn(
        'outline-none ring-2 ring-ring/60 ring-offset-1 cursor-text',
        className,
      )}
      role="textbox"
      aria-multiline="true"
    />
  );
}

function pickButtonVariant(
  raw: unknown,
): 'default' | 'secondary' | 'outline' | 'ghost' | 'destructive' | 'link' {
  if (
    raw === 'secondary' ||
    raw === 'outline' ||
    raw === 'ghost' ||
    raw === 'destructive' ||
    raw === 'link'
  ) {
    return raw;
  }
  return 'default';
}

function pickBadgeVariant(
  raw: unknown,
): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (raw === 'secondary' || raw === 'destructive' || raw === 'outline') {
    return raw;
  }
  return 'default';
}

function pickHeadingLevel(raw: unknown): 1 | 2 | 3 {
  if (raw === 1 || raw === 2 || raw === 3) return raw;
  return 2;
}

// Resolve a lucide icon name to its component. Falls back to a generic
// circle so a typo'd name doesn't blank out the mock.
function pickLucideIcon(raw: unknown): Lucide.LucideIcon {
  if (typeof raw !== 'string') return Lucide.Circle;
  const lookup = (Lucide as unknown as Record<string, Lucide.LucideIcon>)[raw];
  return lookup ?? Lucide.Circle;
}
