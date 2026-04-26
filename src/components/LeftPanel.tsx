'use client';

import AgentSidebar from './AgentSidebar';
import MoodboardPanel from './MoodboardPanel';
import SketchPanel from './SketchPanel';
import UIPanel from './UIPanel';
import type { WorkspaceMode } from '@/lib/workspaceMode';

type Props = {
  agentSidebarOpen: boolean;
  mode: WorkspaceMode;
};

export default function LeftPanel({ agentSidebarOpen, mode }: Props) {
  return (
    <div className="flex h-full w-full">
      <AgentSidebar open={agentSidebarOpen} />
      <div className="min-w-0 flex-1">
        {mode === 'moodboard' ? (
          <MoodboardPanel />
        ) : mode === 'ui' ? (
          <UIPanel />
        ) : (
          <SketchPanel />
        )}
      </div>
    </div>
  );
}
