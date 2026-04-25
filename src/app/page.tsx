'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import AppTopBar from '@/components/AppTopBar';
import LeftPanel from '@/components/LeftPanel';
import WorkspaceGate, { useWorkspace } from '@/components/WorkspaceGate';
import { cn } from '@/lib/utils';

const Terminal = dynamic(() => import('@/components/Terminal'), { ssr: false });

type WorkspaceMode = 'sketch' | 'moodboard' | 'brand';

function HomeBody() {
  const { current, openDialog } = useWorkspace();
  const [agentOpen, setAgentOpen] = useState(true);
  const [claudeOpen, setClaudeOpen] = useState(true);
  const [mode, setMode] = useState<WorkspaceMode>('sketch');

  const workspaceReady = current != null && current.path != null;

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-neutral-950 text-neutral-100">
      <AppTopBar
        agentOpen={agentOpen}
        claudeOpen={claudeOpen}
        mode={mode}
        workspaceName={current?.name ?? null}
        workspacePath={current?.path ?? null}
        workspaceSource={current?.source ?? 'unset'}
        onOpenWorkspaceDialog={openDialog}
        onToggleAgent={() => setAgentOpen((v) => !v)}
        onToggleClaude={() => setClaudeOpen((v) => !v)}
        onModeChange={setMode}
      />
      <main className="flex min-h-0 flex-1">
        <section className="min-w-0 flex-1 bg-neutral-900">
          {workspaceReady ? (
            <LeftPanel agentSidebarOpen={agentOpen} mode={mode} />
          ) : (
            <UnsetPlaceholder />
          )}
        </section>
        <aside
          aria-hidden={!claudeOpen}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-[#0a0a0a] transition-[width] duration-200 ease-out',
            claudeOpen ? 'w-[35vw] min-w-[320px] border-l border-neutral-800' : 'w-0',
          )}
        >
          {workspaceReady ? <Terminal /> : <TerminalPlaceholder />}
        </aside>
      </main>
    </div>
  );
}

function UnsetPlaceholder() {
  return (
    <div className="flex h-full w-full items-center justify-center px-8 text-center text-sm text-neutral-500">
      Pick a project folder to begin.
    </div>
  );
}

function TerminalPlaceholder() {
  return (
    <div className="flex h-full w-full items-center justify-center bg-[#0a0a0a] px-4 text-center text-xs text-neutral-600">
      Claude will start once a workspace is selected.
    </div>
  );
}

export default function Home() {
  return (
    <WorkspaceGate>
      <HomeBody />
    </WorkspaceGate>
  );
}
