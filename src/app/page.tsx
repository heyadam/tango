'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import AppTopBar from '@/components/AppTopBar';
import LeftPanel from '@/components/LeftPanel';
import SimulatorPanel from '@/components/SimulatorPanel';
import WorkspaceGate, { useWorkspace } from '@/components/WorkspaceGate';
import { cn } from '@/lib/utils';
import type { WorkspaceMode } from '@/lib/workspaceMode';

const ChatPanel = dynamic(() => import('@/components/ChatPanel'), {
  ssr: false,
});
const TransmitOverlay = dynamic(() => import('@/components/TransmitOverlay'), {
  ssr: false,
});

function HomeBody() {
  const { current, openDialog } = useWorkspace();
  const [chatOpen, setChatOpen] = useState(true);
  const [simOpen, setSimOpen] = useState(false);
  const [mode, setMode] = useState<WorkspaceMode>('sketch');

  const workspaceReady = current != null && current.path != null;

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-background text-foreground">
      <AppTopBar
        chatOpen={chatOpen}
        simOpen={simOpen}
        workspaceName={current?.name ?? null}
        workspacePath={current?.path ?? null}
        workspaceSource={current?.source ?? 'unset'}
        onOpenWorkspaceDialog={openDialog}
        onToggleChat={() => setChatOpen((v) => !v)}
        onToggleSim={() => setSimOpen((v) => !v)}
      />
      <main className="flex min-h-0 flex-1">
        <section className="min-w-[400px] flex-1 bg-card">
          {workspaceReady ? (
            <LeftPanel mode={mode} onModeChange={setMode} />
          ) : (
            <UnsetPlaceholder />
          )}
        </section>
        <aside
          aria-hidden={!chatOpen}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-background transition-[width] duration-200 ease-out',
            chatOpen ? 'w-[35vw] min-w-[320px] border-l border-border' : 'w-0',
          )}
        >
          {workspaceReady ? (
            <ChatPanel workspacePath={current?.path ?? null} />
          ) : (
            <ChatPlaceholder />
          )}
        </aside>
        <aside
          aria-hidden={!simOpen}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-background transition-[width] duration-200 ease-out',
            simOpen ? 'w-[420px] min-w-[360px] border-l border-border' : 'w-0',
          )}
        >
          {simOpen ? <SimulatorPanel /> : null}
        </aside>
      </main>
      <TransmitOverlay />
    </div>
  );
}

function UnsetPlaceholder() {
  return (
    <div className="flex h-full w-full items-center justify-center px-8 text-center text-sm text-muted-foreground">
      Pick a project folder to begin.
    </div>
  );
}

function ChatPlaceholder() {
  return (
    <div className="flex h-full w-full items-center justify-center bg-background px-4 text-center text-xs text-muted-foreground/60">
      Chat will start once a workspace is selected.
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
