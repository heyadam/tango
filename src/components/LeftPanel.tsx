'use client';

import { useState } from 'react';
import AgentSidebar from './AgentSidebar';
import MoodboardPanel from './MoodboardPanel';
import SketchPanel from './SketchPanel';
import UIPanel from './UIPanel';
import {
  PanelHeaderLeftSlot,
  PanelHeaderRightSlot,
} from '@/lib/leftPanelSlots';
import { cn } from '@/lib/utils';
import type { WorkspaceMode } from '@/lib/workspaceMode';

type Props = {
  agentSidebarOpen: boolean;
  mode: WorkspaceMode;
  onModeChange: (mode: WorkspaceMode) => void;
};

const modes: Array<{ value: WorkspaceMode; label: string }> = [
  { value: 'sketch', label: 'Sketch' },
  { value: 'moodboard', label: 'Moodboard' },
  { value: 'ui', label: 'UI' },
];

export default function LeftPanel({
  agentSidebarOpen,
  mode,
  onModeChange,
}: Props) {
  const [leftSlot, setLeftSlot] = useState<HTMLElement | null>(null);
  const [rightSlot, setRightSlot] = useState<HTMLElement | null>(null);

  return (
    <div className="flex h-full w-full">
      <AgentSidebar open={agentSidebarOpen} />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-12 shrink-0 items-center gap-3 border-b border-border bg-panel-header px-3 text-panel-header-foreground">
          <div
            ref={setLeftSlot}
            className="flex min-w-0 flex-1 items-center gap-2"
          />
          <div
            role="tablist"
            aria-label="Workspace mode"
            className="flex h-8 shrink-0 items-center rounded-md border border-panel-header-foreground/20 bg-panel-header-foreground/10 p-0.5"
          >
            {modes.map((item) => (
              <button
                key={item.value}
                type="button"
                role="tab"
                aria-selected={mode === item.value}
                onClick={() => onModeChange(item.value)}
                className={cn(
                  'h-7 min-w-20 rounded px-2 text-xs font-medium text-panel-header-foreground/70 transition-colors hover:text-panel-header-foreground sm:min-w-24 sm:px-3',
                  mode === item.value &&
                    'bg-panel-header-foreground text-panel-header shadow-sm hover:text-panel-header',
                )}
              >
                {item.label}
              </button>
            ))}
          </div>
          <div
            ref={setRightSlot}
            className="flex min-w-0 flex-1 items-center justify-end gap-2"
          />
        </header>
        <div className="min-h-0 flex-1">
          <PanelHeaderLeftSlot.Provider value={leftSlot}>
            <PanelHeaderRightSlot.Provider value={rightSlot}>
              {mode === 'moodboard' ? (
                <MoodboardPanel />
              ) : mode === 'ui' ? (
                <UIPanel />
              ) : (
                <SketchPanel />
              )}
            </PanelHeaderRightSlot.Provider>
          </PanelHeaderLeftSlot.Provider>
        </div>
      </div>
    </div>
  );
}
