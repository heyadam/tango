'use client';

import {
  Code2,
  LayoutDashboard,
  PanelLeftClose,
  PanelLeftOpen,
  PanelRightClose,
  PanelRightOpen,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

type WorkspaceMode = 'sketch' | 'moodboard' | 'brand';

type Props = {
  agentOpen: boolean;
  claudeOpen: boolean;
  mode: WorkspaceMode;
  onToggleAgent: () => void;
  onToggleClaude: () => void;
  onModeChange: (mode: WorkspaceMode) => void;
};

const modes: Array<{ value: WorkspaceMode; label: string }> = [
  { value: 'sketch', label: 'Sketch' },
  { value: 'moodboard', label: 'Moodboard' },
  { value: 'brand', label: 'Brand' },
];

export default function AppTopBar({
  agentOpen,
  claudeOpen,
  mode,
  onToggleAgent,
  onToggleClaude,
  onModeChange,
}: Props) {
  return (
    <header className="grid h-12 shrink-0 grid-cols-[1fr_auto_1fr] items-center border-b border-neutral-800 bg-neutral-950 px-2">
      <div className="flex items-center gap-2">
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleAgent}
          aria-label={agentOpen ? 'Hide agent sidebar' : 'Show agent sidebar'}
          aria-pressed={agentOpen}
          className="text-neutral-400 hover:text-neutral-100"
        >
          {agentOpen ? (
            <PanelLeftClose className="size-4" />
          ) : (
            <PanelLeftOpen className="size-4" />
          )}
        </Button>
        <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-300">
          <LayoutDashboard className="size-3.5 text-neutral-500" />
          <span>Tango</span>
        </div>
      </div>

      <div
        role="tablist"
        aria-label="Workspace mode"
        className="flex h-8 items-center rounded-md border border-neutral-800 bg-neutral-900 p-0.5"
      >
        {modes.map((item) => (
          <button
            key={item.value}
            type="button"
            role="tab"
            aria-selected={mode === item.value}
            onClick={() => onModeChange(item.value)}
            className={cn(
              'h-7 min-w-20 rounded px-2 text-xs font-medium text-neutral-400 transition-colors hover:text-neutral-100 sm:min-w-24 sm:px-3',
              mode === item.value &&
                'bg-neutral-100 text-neutral-950 shadow-sm hover:text-neutral-950',
            )}
          >
            {item.label}
          </button>
        ))}
      </div>

      <div className="flex items-center justify-end gap-2">
        <div className="hidden items-center gap-1.5 text-xs font-medium text-neutral-300 sm:flex">
          <Code2 className="size-3.5 text-neutral-500" />
          <span>Claude Code</span>
        </div>
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleClaude}
          aria-label={
            claudeOpen ? 'Hide Claude Code sidebar' : 'Show Claude Code sidebar'
          }
          aria-pressed={claudeOpen}
          className="text-neutral-400 hover:text-neutral-100"
        >
          {claudeOpen ? (
            <PanelRightClose className="size-4" />
          ) : (
            <PanelRightOpen className="size-4" />
          )}
        </Button>
      </div>
    </header>
  );
}
