'use client';

import { useCallback, useRef, useState } from 'react';
import AgentSidebar from './AgentSidebar';
import MoodboardPanel from './MoodboardPanel';
import SketchPanel from './SketchPanel';
import UIPanel from './UIPanel';
import type { DesignerHandles } from './DesignerCanvas';
import { writeSnapshot } from '@/lib/designSnapshot';
import { terminalBus } from '@/lib/terminalBus';
import type { WorkspaceMode } from '@/lib/workspaceMode';

type Props = {
  agentSidebarOpen: boolean;
  mode: WorkspaceMode;
};

export default function LeftPanel({ agentSidebarOpen, mode }: Props) {
  const handlesRef = useRef<DesignerHandles | null>(null);
  const [sendBusy, setSendBusy] = useState(false);

  const onCanvasReady = useCallback((handles: DesignerHandles) => {
    handlesRef.current = handles;
  }, []);

  const sendSketch = useCallback(
    async (caption?: string) => {
      if (!handlesRef.current || sendBusy) return null;
      setSendBusy(true);
      try {
        const blob = await handlesRef.current.getPng();
        const { relPath } = await writeSnapshot(blob, { caption });
        const note = caption && caption.trim() ? ` — ${caption.trim()}` : '';
        terminalBus.sendToTerminal(`# review design at ${relPath}${note}\n`);
        return relPath;
      } finally {
        setSendBusy(false);
      }
    },
    [sendBusy],
  );

  return (
    <div className="flex h-full w-full">
      <AgentSidebar
        open={agentSidebarOpen}
        onSendSketch={sendSketch}
        sendBusy={sendBusy}
        canSendSketch={mode === 'sketch'}
      />
      <div className="min-w-0 flex-1">
        {mode === 'moodboard' ? (
          <MoodboardPanel />
        ) : mode === 'ui' ? (
          <UIPanel />
        ) : (
          <SketchPanel onCanvasReady={onCanvasReady} />
        )}
      </div>
    </div>
  );
}
