'use client';

import { useCallback, useEffect, useState } from 'react';
import dynamic from 'next/dynamic';
import AppTopBar from '@/components/AppTopBar';
import SimulatorPanel from '@/components/SimulatorPanel';
import UIPanel from '@/components/UIPanel';
import WorkspaceGate, { useWorkspace } from '@/components/WorkspaceGate';
import {
  DEFAULT_TERMINAL_AGENT,
  TERMINAL_AGENTS,
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { cn } from '@/lib/utils';

const Terminal = dynamic(() => import('@/components/Terminal'), { ssr: false });

function HomeBody() {
  const { current, openDialog } = useWorkspace();
  const [terminalOpen, setTerminalOpen] = useState(true);
  const [simOpen, setSimOpen] = useState(false);
  const [terminalAgent, setTerminalAgent] = useState<TerminalAgentId>(
    DEFAULT_TERMINAL_AGENT,
  );

  const workspaceReady = current != null && current.path != null;

  const refreshTerminalAgent = useCallback(async () => {
    try {
      const res = await fetch('/api/terminal-agent', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as { agent?: unknown };
      if (isTerminalAgentId(body.agent)) setTerminalAgent(body.agent);
    } catch {
      setTerminalAgent(DEFAULT_TERMINAL_AGENT);
    }
  }, []);

  useEffect(() => {
    void refreshTerminalAgent();
  }, [refreshTerminalAgent]);

  const persistTerminalAgent = useCallback(
    async (next: TerminalAgentId) => {
      setTerminalAgent(next);
      try {
        const res = await fetch('/api/terminal-agent', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ agent: next }),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
      } catch {
        void refreshTerminalAgent();
      }
    },
    [refreshTerminalAgent],
  );

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-background text-foreground">
      <AppTopBar
        terminalOpen={terminalOpen}
        simOpen={simOpen}
        terminalAgent={terminalAgent}
        workspaceName={current?.name ?? null}
        workspacePath={current?.path ?? null}
        workspaceSource={current?.source ?? 'unset'}
        onOpenWorkspaceDialog={openDialog}
        onToggleTerminal={() => setTerminalOpen((v) => !v)}
        onToggleSim={() => setSimOpen((v) => !v)}
        onTerminalAgentChange={(agent) => {
          void persistTerminalAgent(agent);
        }}
      />
      <main className="flex min-h-0 flex-1">
        <section className="min-w-[400px] flex-1 bg-card">
          {workspaceReady ? (
            <UIPanel terminalAgent={terminalAgent} />
          ) : (
            <UnsetPlaceholder />
          )}
        </section>
        <aside
          aria-hidden={!terminalOpen}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-background transition-[width] duration-200 ease-out',
            terminalOpen
              ? 'w-[35vw] min-w-[320px] border-l border-border'
              : 'w-0',
          )}
        >
          {workspaceReady ? (
            <Terminal
              terminalAgent={terminalAgent}
              onTerminalAgentChanged={setTerminalAgent}
            />
          ) : (
            <TerminalPlaceholder terminalAgent={terminalAgent} />
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

function TerminalPlaceholder({
  terminalAgent,
}: {
  terminalAgent: TerminalAgentId;
}) {
  return (
    <div className="flex h-full w-full items-center justify-center bg-background px-4 text-center text-xs text-muted-foreground/60">
      {TERMINAL_AGENTS[terminalAgent].placeholder}
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
