'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import WorkspaceDialog from './WorkspaceDialog';
import { workspaceBus } from '@/lib/workspaceBus';

type WorkspaceCurrent = {
  path: string | null;
  name: string | null;
  source: 'env' | 'persisted' | 'unset';
};

type Ctx = {
  // null while the initial /api/workspace/current fetch is in-flight. Consumers
  // that gate UI on the current workspace should treat null as "unknown" and
  // render a placeholder.
  current: WorkspaceCurrent | null;
  openDialog: () => void;
};

const WorkspaceContext = createContext<Ctx | null>(null);

export function useWorkspace(): Ctx {
  const ctx = useContext(WorkspaceContext);
  if (!ctx) throw new Error('useWorkspace must be used within WorkspaceGate');
  return ctx;
}

type Props = {
  children: ReactNode;
};

export default function WorkspaceGate({ children }: Props) {
  const [current, setCurrent] = useState<WorkspaceCurrent | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);

  const refreshCurrent = useCallback(async () => {
    try {
      const res = await fetch('/api/workspace/current', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as WorkspaceCurrent;
      setCurrent(body);
    } catch {
      setCurrent({ path: null, name: null, source: 'unset' });
    }
  }, []);

  useEffect(() => {
    void refreshCurrent();
  }, [refreshCurrent]);

  // When the picker successfully sets a workspace it emits on workspaceBus.
  // Optimistically update local state so the blocking dialog closes right
  // away (otherwise it stays open until the async /current re-fetch returns
  // and re-renders blocking=false). Then refresh from the server to confirm
  // and pick up the canonical source.
  useEffect(() => {
    return workspaceBus.subscribe((event) => {
      setCurrent((prev) => ({
        path: event.path,
        name: event.name,
        source: prev?.source === 'env' ? 'env' : 'persisted',
      }));
      void refreshCurrent();
    });
  }, [refreshCurrent]);

  const openDialog = useCallback(() => {
    setDialogOpen(true);
  }, []);

  const ctxValue = useMemo<Ctx>(
    () => ({ current, openDialog }),
    [current, openDialog],
  );

  // First-launch blocking picker: once we've heard back from /current and the
  // path is null and not env-pinned, force the dialog open.
  const blocking = current != null && current.path == null && current.source !== 'env';
  const dialogVisible = blocking || dialogOpen;

  return (
    <WorkspaceContext.Provider value={ctxValue}>
      {children}
      {current != null && (
        <WorkspaceDialog
          open={dialogVisible}
          onOpenChange={setDialogOpen}
          current={current}
          blocking={blocking}
        />
      )}
    </WorkspaceContext.Provider>
  );
}
