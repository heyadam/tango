import * as React from 'react';
import type { LucideIcon } from 'lucide-react';

import { cn } from '@/lib/utils';

type Props = {
  /** Optional leading icon. Sized at 3.5 with reduced opacity to match other headers. */
  icon?: LucideIcon;
  /** Optional title text. Rendered next to the icon. */
  title?: React.ReactNode;
  /**
   * Composable slots for headers that need more than icon+title.
   * `leftSlot`/`rightSlot` flex-grow to fill space; `centerSlot` does not.
   * If only `icon`+`title` are provided, they fill the left slot automatically.
   */
  leftSlot?: React.ReactNode;
  centerSlot?: React.ReactNode;
  rightSlot?: React.ReactNode;
  /**
   * Refs to the slot wrappers, for consumers that need to portal into them
   * (see [src/lib/leftPanelSlots.ts](src/lib/leftPanelSlots.ts)).
   */
  leftSlotRef?: React.Ref<HTMLDivElement>;
  rightSlotRef?: React.Ref<HTMLDivElement>;
  className?: string;
};

export default function PanelHeader({
  icon: Icon,
  title,
  leftSlot,
  centerSlot,
  rightSlot,
  leftSlotRef,
  rightSlotRef,
  className,
}: Props) {
  const hasSlots =
    leftSlot != null ||
    centerSlot != null ||
    rightSlot != null ||
    leftSlotRef != null ||
    rightSlotRef != null;

  return (
    <header
      className={cn(
        'flex h-12 shrink-0 items-center gap-3 border-b border-border bg-panel-header px-3 text-xs font-medium text-panel-header-foreground',
        className
      )}
    >
      {hasSlots ? (
        <>
          <div
            ref={leftSlotRef}
            className="flex min-w-0 flex-1 items-center gap-2"
          >
            {leftSlot ?? <DefaultLabel Icon={Icon} title={title} />}
          </div>
          {centerSlot && <div className="shrink-0">{centerSlot}</div>}
          <div
            ref={rightSlotRef}
            className="flex min-w-0 flex-1 items-center justify-end gap-2"
          >
            {rightSlot}
          </div>
        </>
      ) : (
        <div className="flex min-w-0 items-center gap-1.5">
          <DefaultLabel Icon={Icon} title={title} />
        </div>
      )}
    </header>
  );
}

function DefaultLabel({
  Icon,
  title,
}: {
  Icon?: LucideIcon;
  title?: React.ReactNode;
}) {
  if (!Icon && !title) return null;
  return (
    <>
      {Icon && <Icon className="size-3.5 text-panel-header-foreground/70" />}
      {title && <span>{title}</span>}
    </>
  );
}
