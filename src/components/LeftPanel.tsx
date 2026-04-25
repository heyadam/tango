'use client';

import { useCallback, useRef, useState } from 'react';
import AgentSidebar from './AgentSidebar';
import SketchPanel from './SketchPanel';
import type { DesignerHandles } from './DesignerCanvas';
import { writeSnapshot } from '@/lib/designSnapshot';
import { terminalBus } from '@/lib/terminalBus';

type Props = {
  agentSidebarOpen: boolean;
};

export default function LeftPanel({ agentSidebarOpen }: Props) {
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
      />
      <div className="min-w-0 flex-1">
        <SketchPanel onCanvasReady={onCanvasReady} />
      </div>
    </div>
  );
}
