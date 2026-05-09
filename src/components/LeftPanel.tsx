'use client';

import { useState } from 'react';
import MoodboardPanel from './MoodboardPanel';
import PanelHeader from './PanelHeader';
import SketchPanel from './SketchPanel';
import UIPanel from './UIPanel';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  PanelHeaderLeftSlot,
  PanelHeaderRightSlot,
} from '@/lib/leftPanelSlots';
import type { WorkspaceMode } from '@/lib/workspaceMode';

type Props = {
  mode: WorkspaceMode;
  onModeChange: (mode: WorkspaceMode) => void;
};

const modes: Array<{ value: WorkspaceMode; label: string }> = [
  { value: 'sketch', label: 'Sketch' },
  { value: 'moodboard', label: 'Moodboard' },
  { value: 'ui', label: 'UI' },
];

export default function LeftPanel({ mode, onModeChange }: Props) {
  const [leftSlot, setLeftSlot] = useState<HTMLElement | null>(null);
  const [rightSlot, setRightSlot] = useState<HTMLElement | null>(null);

  return (
    <div className="flex h-full w-full">
      <Tabs
        value={mode}
        onValueChange={(v) => onModeChange(v as WorkspaceMode)}
        activationMode="manual"
        className="flex min-w-0 flex-1 flex-col gap-0"
      >
        <PanelHeader
          leftSlotRef={setLeftSlot}
          rightSlotRef={setRightSlot}
          centerSlot={
            <TabsList
              aria-label="Workspace mode"
              className="bg-panel-header-foreground/10 border border-panel-header-foreground/20 text-panel-header-foreground/70"
            >
              {modes.map((item) => (
                <TabsTrigger
                  key={item.value}
                  value={item.value}
                  className="min-w-20 sm:min-w-24 sm:px-3 hover:text-panel-header-foreground data-[state=active]:bg-panel-header-foreground data-[state=active]:text-panel-header"
                >
                  {item.label}
                </TabsTrigger>
              ))}
            </TabsList>
          }
        />
        <div className="min-h-0 flex-1">
          <PanelHeaderLeftSlot.Provider value={leftSlot}>
            <PanelHeaderRightSlot.Provider value={rightSlot}>
              <TabsContent value="sketch" className="h-full">
                <SketchPanel />
              </TabsContent>
              <TabsContent value="moodboard" className="h-full">
                <MoodboardPanel />
              </TabsContent>
              <TabsContent value="ui" className="h-full">
                <UIPanel />
              </TabsContent>
            </PanelHeaderRightSlot.Provider>
          </PanelHeaderLeftSlot.Provider>
        </div>
      </Tabs>
    </div>
  );
}
