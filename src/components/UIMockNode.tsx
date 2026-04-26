'use client';

// Renders a single UINode by `type` to its corresponding shadcn primitive (or
// a layout primitive for `div` / `text` / `heading` / `Image`). Every node
// fills its bounding box with `w-full h-full` so the wrapper's absolute
// positioning is the single source of truth for size — drag/resize math in
// the canvas writes back to the node's x/y/width/height, never touches inner
// styling. The node's optional `className` rides on top via tailwind-merge.

import { type ReactNode, useEffect, useRef } from 'react';
import * as Lucide from 'lucide-react';
import { Badge } from './ui/badge';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Separator } from './ui/separator';
import { Textarea } from './ui/textarea';
import { cn } from '@/lib/utils';
import type { UINode } from '@/lib/uiMockProtocol';

type Props = {
  node: UINode;
  isEditing: boolean;
  onCommitText: (text: string) => void;
  onEndEdit: () => void;
};

export default function UIMockNode({
  node,
  isEditing,
  onCommitText,
  onEndEdit,
}: Props) {
  switch (node.type) {
    case 'div':
      return (
        <div
          className={cn(
            'h-full w-full rounded-md border border-dashed border-border/60 bg-muted/30',
            node.className,
          )}
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
            'h-full w-full overflow-hidden whitespace-pre-wrap tracking-tight text-foreground',
            fontSize,
            node.className,
          )}
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
        />
      );
    }

    case 'Badge': {
      const variant = pickBadgeVariant(node.props?.variant);
      return (
        <div className="flex h-full w-full items-center justify-center">
          <Badge variant={variant} className={cn(node.className)}>
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
          <Icon className={cn('size-full text-foreground', node.className)} />
        </div>
      );
    }

    default:
      return null;
  }
}

function Editable({
  isEditing,
  value,
  onCommit,
  onEnd,
  className,
}: {
  isEditing: boolean;
  value: string;
  onCommit: (text: string) => void;
  onEnd: () => void;
  className?: string;
}): ReactNode {
  const ref = useRef<HTMLDivElement | null>(null);

  // When edit mode starts, focus and select-all so the user can immediately
  // overwrite the text. We can't put `value` in the JSX of a contentEditable
  // (React would fight us); set it imperatively on mount.
  useEffect(() => {
    if (!isEditing) return;
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
  }, [isEditing, value]);

  if (!isEditing) {
    return <div className={className}>{value}</div>;
  }

  return (
    <div
      ref={ref}
      contentEditable
      suppressContentEditableWarning
      // Stop pointerdown from bubbling up to react-moveable so clicks land
      // inside the editor instead of starting a drag.
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          const next = (e.currentTarget.textContent ?? '').trim();
          onCommit(next);
          onEnd();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          onEnd();
        }
      }}
      onBlur={(e) => {
        const next = (e.currentTarget.textContent ?? '').trim();
        onCommit(next);
        onEnd();
      }}
      className={cn(
        'outline-none ring-2 ring-blue-500/60 ring-offset-1 cursor-text',
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
