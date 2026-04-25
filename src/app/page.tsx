'use client';

import dynamic from 'next/dynamic';
import { Group, Panel, Separator } from 'react-resizable-panels';
import LeftPanel from '@/components/LeftPanel';

const Terminal = dynamic(() => import('@/components/Terminal'), { ssr: false });

export default function Home() {
  return (
    <Group orientation="horizontal" className="flex h-screen w-screen">
      <Panel
        defaultSize="65%"
        minSize="25%"
        className="bg-neutral-900 text-neutral-100"
      >
        <LeftPanel />
      </Panel>
      <Separator className="group relative w-px shrink-0 bg-neutral-800 transition-colors hover:bg-neutral-600 data-[resize-handle-active]:bg-neutral-500">
        <div className="absolute inset-y-0 -left-1 w-3" />
      </Separator>
      <Panel defaultSize="35%" minSize="20%" className="bg-[#0a0a0a]">
        <Terminal />
      </Panel>
    </Group>
  );
}
