'use client';

import {
  Folder,
  FolderOpen,
  Lock,
  MessageSquare,
  PanelRightClose,
  PanelRightOpen,
  Smartphone,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import TangoLogo from '@/components/TangoLogo';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import { cn } from '@/lib/utils';

type WorkspaceSource = 'env' | 'persisted' | 'unset';

type Props = {
  chatOpen: boolean;
  simOpen: boolean;
  workspaceName: string | null;
  workspacePath: string | null;
  workspaceSource: WorkspaceSource;
  onOpenWorkspaceDialog: () => void;
  onToggleChat: () => void;
  onToggleSim: () => void;
};

export default function AppTopBar({
  chatOpen,
  simOpen,
  workspaceName,
  workspacePath,
  workspaceSource,
  onOpenWorkspaceDialog,
  onToggleChat,
  onToggleSim,
}: Props) {
  return (
    <header className="flex h-12 shrink-0 items-center justify-between border-b border-border bg-background px-2">
      <div className="flex items-center gap-2">
        <div className="flex items-center gap-1.5 font-serif text-sm font-semibold tracking-tight text-foreground">
          <TangoLogo className="size-5" />
          <span>tango</span>
        </div>
        <span className="text-muted-foreground/60">/</span>
        <WorkspacePill
          name={workspaceName}
          path={workspacePath}
          source={workspaceSource}
          onClick={onOpenWorkspaceDialog}
        />
      </div>

      <div className="flex items-center justify-end gap-2">
        <div className="hidden items-center gap-1.5 text-xs font-medium text-foreground sm:flex">
          <MessageSquare className="size-3.5 text-muted-foreground" />
          <span>Chat</span>
        </div>
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleChat}
          aria-label={chatOpen ? 'Hide chat sidebar' : 'Show chat sidebar'}
          aria-pressed={chatOpen}
          className="text-muted-foreground hover:text-foreground"
        >
          {chatOpen ? (
            <PanelRightClose className="size-4" />
          ) : (
            <PanelRightOpen className="size-4" />
          )}
        </Button>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={onToggleSim}
              aria-label={simOpen ? 'Hide simulator sidebar' : 'Show simulator sidebar'}
              aria-pressed={simOpen}
              className={cn(
                'text-muted-foreground hover:text-foreground',
                simOpen && 'text-foreground',
              )}
            >
              <Smartphone className="size-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="bottom">
            {simOpen ? 'Hide simulator' : 'Show simulator'}
          </TooltipContent>
        </Tooltip>
      </div>
    </header>
  );
}

function WorkspacePill({
  name,
  path,
  source,
  onClick,
}: {
  name: string | null;
  path: string | null;
  source: WorkspaceSource;
  onClick: () => void;
}) {
  const label = name ?? 'No workspace';
  const isUnset = path == null;
  const isEnvLocked = source === 'env';

  const tooltipBody = isUnset
    ? 'Click to pick a project folder.'
    : isEnvLocked
      ? `${path}\n\nPinned by TANGO_WORKSPACE — picker is read-only.`
      : path;

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant={isUnset ? 'warning' : 'outline'}
          size="sm"
          onClick={onClick}
          aria-label={`Workspace: ${label}. Click to change.`}
          className={cn(
            'gap-1.5 px-2 text-xs font-medium',
            !isUnset && 'bg-muted hover:bg-accent',
          )}
        >
          {isUnset ? (
            <FolderOpen className="size-3.5" />
          ) : (
            <Folder className="size-3.5 text-muted-foreground" />
          )}
          <span className="max-w-[16ch] truncate sm:max-w-[24ch]">{label}</span>
          {isEnvLocked && <Lock className="size-3 text-muted-foreground" />}
        </Button>
      </TooltipTrigger>
      <TooltipContent side="bottom" className="max-w-[28rem] whitespace-pre-line break-all font-mono">
        {tooltipBody}
      </TooltipContent>
    </Tooltip>
  );
}
