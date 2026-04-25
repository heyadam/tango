'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import AppTopBar from '@/components/AppTopBar';
import LeftPanel from '@/components/LeftPanel';
import { cn } from '@/lib/utils';

const Terminal = dynamic(() => import('@/components/Terminal'), { ssr: false });

type WorkspaceMode = 'sketch' | 'moodboard' | 'brand';

export default function Home() {
  const [agentOpen, setAgentOpen] = useState(true);
  const [claudeOpen, setClaudeOpen] = useState(true);
  const [mode, setMode] = useState<WorkspaceMode>('sketch');

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-neutral-950 text-neutral-100">
      <AppTopBar
        agentOpen={agentOpen}
        claudeOpen={claudeOpen}
        mode={mode}
        onToggleAgent={() => setAgentOpen((v) => !v)}
        onToggleClaude={() => setClaudeOpen((v) => !v)}
        onModeChange={setMode}
      />
      <main className="flex min-h-0 flex-1">
        <section className="min-w-0 flex-1 bg-neutral-900">
          <LeftPanel agentSidebarOpen={agentOpen} />
        </section>
        <aside
          aria-hidden={!claudeOpen}
          className={cn(
            'h-full shrink-0 overflow-hidden bg-[#0a0a0a] transition-[width] duration-200 ease-out',
            claudeOpen ? 'w-[35vw] min-w-[320px] border-l border-neutral-800' : 'w-0',
          )}
        >
          <Terminal />
        </aside>
      </main>
    </div>
  );
}
