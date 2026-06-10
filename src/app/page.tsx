'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import AgentPanel from '@/components/AgentPanel';
import AppTopBar from '@/components/AppTopBar';
import SimulatorPanel from '@/components/SimulatorPanel';
import UIPanel from '@/components/UIPanel';
import WorkspaceGate, { useWorkspace } from '@/components/WorkspaceGate';
import {
  DEFAULT_TERMINAL_AGENT,
  TERMINAL_AGENTS,
  isPtyAgent,
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { terminalBus } from '@/lib/terminalBus';
import { cn } from '@/lib/utils';

const Terminal = dynamic(() => import('@/components/Terminal'), { ssr: false });

const LS_AGENT_WIDTH = 'TANGO_AGENT_SIDEBAR_WIDTH';

// Kick the chunk download immediately on page load instead of waiting for the
// workspace fetch to resolve and the component to mount — the dynamic() above
// stays as the SSR boundary (xterm dies on SSR), this just warms the cache.
if (typeof window !== 'undefined') {
  void import('@/components/Terminal');
}

function HomeBody() {
  const { current, openDialog } = useWorkspace();
  const [terminalOpen, setTerminalOpen] = useState(true);
  const [simOpen, setSimOpen] = useState(false);
  const [terminalAgent, setTerminalAgent] = useState<TerminalAgentId>(
    DEFAULT_TERMINAL_AGENT,
  );

  const [agentWidth, setAgentWidth] = useState(400);
  const [isResizing, setIsResizing] = useState(false);
  const agentWidthRef = useRef(400);
  const cleanupResizeRef = useRef<(() => void) | null>(null);

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

  useEffect(() => {
    const saved = localStorage.getItem(LS_AGENT_WIDTH);
    if (saved) {
      const n = parseInt(saved, 10);
      if (n >= 280 && n <= 900) {
        setAgentWidth(n);
        agentWidthRef.current = n;
      }
    }
  }, []);

  useEffect(() => () => cleanupResizeRef.current?.(), []);

  function handleResizeStart(e: React.PointerEvent) {
    e.preventDefault();
    const startX = e.clientX;
    const startW = agentWidthRef.current;
    setIsResizing(true);
    document.body.style.cursor = 'col-resize';

    function move(ev: PointerEvent) {
      const next = Math.max(280, Math.min(900, startW + ev.clientX - startX));
      agentWidthRef.current = next;
      setAgentWidth(next);
    }

    function end() {
      setIsResizing(false);
      document.body.style.cursor = '';
      localStorage.setItem(LS_AGENT_WIDTH, String(agentWidthRef.current));
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', end);
      cleanupResizeRef.current = null;
    }

    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', end);
    cleanupResizeRef.current = end;
  }

  // Canvas tasks auto-expand a collapsed sidebar: the agent panel stays
  // mounted while collapsed (so delivery already works) — this makes the
  // result visible, including AgentPanel's 'not connected' error row.
  useEffect(() => terminalBus.onTaskSubmitted(() => setTerminalOpen(true)), []);

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
        {/* Agent/terminal sidebar — sits left of the design canvas. The
            children stay mounted while collapsed (the WS/PTY must survive),
            so `inert` (not aria-hidden) is load-bearing: it also removes the
            hidden textarea/buttons from the tab order and makes AgentPanel's
            focus() on reconnect a no-op while hidden. */}
        <aside
          inert={!terminalOpen}
          style={terminalOpen ? { width: agentWidth } : undefined}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-background',
            terminalOpen ? '' : 'w-0',
            isResizing
              ? 'transition-none'
              : 'transition-[width] duration-200 ease-out',
          )}
        >
          {workspaceReady ? (
            isPtyAgent(terminalAgent) ? (
              <Terminal
                terminalAgent={terminalAgent}
                onTerminalAgentChanged={setTerminalAgent}
              />
            ) : (
              <AgentPanel
                terminalAgent={terminalAgent}
                onTerminalAgentChanged={setTerminalAgent}
              />
            )
          ) : current == null ? (
            <PanelSkeleton />
          ) : (
            <TerminalPlaceholder terminalAgent={terminalAgent} />
          )}
        </aside>
        {terminalOpen && (
          <div
            className="z-10 w-1 shrink-0 cursor-col-resize select-none bg-border transition-colors hover:bg-primary/40 active:bg-primary/60"
            onPointerDown={handleResizeStart}
          />
        )}
        <section className="min-w-[400px] flex-1 bg-card">
          {workspaceReady ? (
            <UIPanel terminalAgent={terminalAgent} />
          ) : current == null ? (
            <PanelSkeleton withHeader />
          ) : (
            <UnsetPlaceholder />
          )}
        </section>
        <aside
          inert={!simOpen}
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

// Shown while the initial /api/workspace/current fetch is in flight, so first
// paint reads as a loading app rather than empty panes.
function PanelSkeleton({ withHeader = false }: { withHeader?: boolean }) {
  return (
    <div className="flex h-full w-full flex-col">
      {withHeader && (
        <div className="flex h-12 shrink-0 items-center gap-3 border-b border-border px-3">
          <div className="h-4 w-24 animate-pulse rounded bg-muted" />
        </div>
      )}
      <div className="flex min-h-0 flex-1 items-start gap-4 p-6">
        <div className="h-2/3 w-full max-w-md animate-pulse rounded-lg bg-muted" />
      </div>
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
