'use client';

import { useCallback, useRef, useState } from 'react';
import AgentSidebar from './AgentSidebar';
import MoodboardPanel from './MoodboardPanel';
import SketchPanel from './SketchPanel';
import type { DesignerHandles } from './DesignerCanvas';
import { writeSnapshot } from '@/lib/designSnapshot';
import { terminalBus } from '@/lib/terminalBus';

type WorkspaceMode = 'sketch' | 'moodboard' | 'brand';

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

  const sendSketch = useCallback(async () => {
    if (!handlesRef.current || sendBusy) return null;
    setSendBusy(true);
    try {
      const blob = await handlesRef.current.getPng();
      const { relPath } = await writeSnapshot(blob);
      terminalBus.sendToTerminal(`# review design at ${relPath}\n`);
      return relPath;
    } finally {
      setSendBusy(false);
    }
  }, [sendBusy]);

  return (
    <div className="flex h-full w-full">
      <AgentSidebar
        open={agentSidebarOpen}
        onSendSketch={sendSketch}
        sendBusy={sendBusy}
        canSendSketch={mode !== 'moodboard'}
      />
      <div className="min-w-0 flex-1">
        {mode === 'moodboard' ? (
          <MoodboardPanel />
        ) : (
          <SketchPanel onCanvasReady={onCanvasReady} />
        )}
      </div>
    </div>
  );
}
