'use client';

// Floating "add element" palette for UI mode. Presentational: it just renders
// one button per node type and calls `onAdd(type)`. Placement of the new node
// (target screen + coords + selection) is the canvas's job — see
// UIMockCanvas.addNodeOfType. Lives as an overlay inside UIMockCanvas because
// that's where the spec/selection state and mutators are.

import {
  Circle,
  Heading,
  Image as ImageIcon,
  MousePointerClick,
  Minus,
  MoveUpRight,
  Slash,
  Sparkle,
  Square,
  SquareRoundCorner,
  Star,
  Tag,
  TextCursorInput,
  Triangle,
  Type,
  WrapText,
  X,
} from 'lucide-react';
import type { ComponentType } from 'react';
import { Button } from './ui/button';
import {
  NODE_LABELS,
  NODE_TYPE_ORDER,
  SHAPE_TYPE_ORDER,
} from '@/lib/uiMockDefaults';
import { Component } from 'lucide-react';
import type { UINodeType } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

const ICONS: Record<UINodeType, ComponentType<{ className?: string }>> = {
  div: Square,
  text: Type,
  heading: Heading,
  rect: SquareRoundCorner,
  ellipse: Circle,
  line: Slash,
  arrow: MoveUpRight,
  triangle: Triangle,
  star: Star,
  Button: MousePointerClick,
  Input: TextCursorInput,
  Textarea: WrapText,
  Badge: Tag,
  Separator: Minus,
  Image: ImageIcon,
  Icon: Sparkle,
};

// Shared by the palette rows and the shape toolbar in UIMockCanvas.
export const SHAPE_ICONS = ICONS;

type Props = {
  onAdd: (type: UINodeType) => void;
  onClose: () => void;
  disabled?: boolean;
  // Imported design-library components (spec.components summaries). When
  // present, a "Components" section lists them; insertion (fresh ids, group,
  // placement) is the canvas's job — same division of labor as onAdd.
  components?: Array<{ id: string; name: string }>;
  onAddComponent?: (componentId: string) => void;
};

function PaletteRow({
  type,
  onAdd,
}: {
  type: UINodeType;
  onAdd: (type: UINodeType) => void;
}) {
  const Icon = ICONS[type];
  return (
    <button
      type="button"
      onClick={() => onAdd(type)}
      className={cn(
        'flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm text-foreground',
        'hover:bg-accent',
      )}
    >
      <Icon className="size-4 text-muted-foreground" />
      {NODE_LABELS[type]}
    </button>
  );
}

export default function UIAddPalette({
  onAdd,
  onClose,
  disabled,
  components,
  onAddComponent,
}: Props) {
  return (
    <div
      // Stop pointer events from reaching the canvas (which would clear
      // selection / start a drag).
      onPointerDown={(e) => e.stopPropagation()}
      className="flex max-h-[70vh] w-44 flex-col gap-1 overflow-y-auto rounded-lg border border-border bg-card p-2 shadow-lg"
    >
      <div className="flex items-center justify-between px-1 pb-1">
        <span className="text-xs font-medium text-muted-foreground">
          Add element
        </span>
        <Button
          variant="ghost"
          size="icon"
          className="size-6 text-muted-foreground hover:bg-accent"
          onClick={onClose}
          aria-label="Close add palette"
        >
          <X className="size-3.5" />
        </Button>
      </div>
      {disabled ? (
        <p className="px-1 py-2 text-xs text-muted-foreground">
          Add a screen first, then drop elements here.
        </p>
      ) : (
        <>
          {NODE_TYPE_ORDER.map((type) => (
            <PaletteRow key={type} type={type} onAdd={onAdd} />
          ))}
          <div className="px-1 pb-1 pt-2 text-xs font-medium text-muted-foreground">
            Shapes
          </div>
          {SHAPE_TYPE_ORDER.map((type) => (
            <PaletteRow key={type} type={type} onAdd={onAdd} />
          ))}
          {components && components.length > 0 && onAddComponent ? (
            <>
              <div className="px-1 pb-1 pt-2 text-xs font-medium text-muted-foreground">
                Components
              </div>
              {components.map((c) => (
                <button
                  key={c.id}
                  type="button"
                  onClick={() => onAddComponent(c.id)}
                  className={cn(
                    'flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm text-foreground',
                    'hover:bg-accent',
                  )}
                >
                  <Component className="size-4 text-muted-foreground" />
                  <span className="truncate">{c.name}</span>
                </button>
              ))}
            </>
          ) : null}
        </>
      )}
    </div>
  );
}
