'use client';

import {
  Code2,
  Folder,
  FolderOpen,
  Lock,
  PanelLeftClose,
  PanelLeftOpen,
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
  agentOpen: boolean;
  claudeOpen: boolean;
  simOpen: boolean;
  workspaceName: string | null;
  workspacePath: string | null;
  workspaceSource: WorkspaceSource;
  onOpenWorkspaceDialog: () => void;
  onToggleAgent: () => void;
  onToggleClaude: () => void;
  onToggleSim: () => void;
};

export default function AppTopBar({
  agentOpen,
  claudeOpen,
  simOpen,
  workspaceName,
  workspacePath,
  workspaceSource,
  onOpenWorkspaceDialog,
  onToggleAgent,
  onToggleClaude,
  onToggleSim,
}: Props) {
  return (
    <header className="flex h-12 shrink-0 items-center justify-between border-b border-border bg-background px-2">
      <div className="flex items-center gap-2">
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleAgent}
          aria-label={agentOpen ? 'Hide agent sidebar' : 'Show agent sidebar'}
          aria-pressed={agentOpen}
          className="text-muted-foreground hover:text-foreground"
        >
          {agentOpen ? (
            <PanelLeftClose className="size-4" />
          ) : (
            <PanelLeftOpen className="size-4" />
          )}
        </Button>
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
          <Code2 className="size-3.5 text-muted-foreground" />
          <span>Claude Code</span>
        </div>
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleClaude}
          aria-label={
            claudeOpen ? 'Hide Claude Code sidebar' : 'Show Claude Code sidebar'
          }
          aria-pressed={claudeOpen}
          className="text-muted-foreground hover:text-foreground"
        >
          {claudeOpen ? (
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
        <button
          type="button"
          onClick={onClick}
          aria-label={`Workspace: ${label}. Click to change.`}
          className={cn(
            'flex h-7 items-center gap-1.5 rounded-md border px-2 text-xs font-medium transition-colors',
            isUnset
              ? 'border-orange-300 bg-orange-100 text-orange-900 hover:border-orange-400 hover:bg-orange-200'
              : 'border-border bg-muted text-foreground hover:border-foreground/30 hover:bg-accent',
          )}
        >
          {isUnset ? (
            <FolderOpen className="size-3.5 text-orange-600" />
          ) : (
            <Folder className="size-3.5 text-muted-foreground" />
          )}
          <span className="max-w-[16ch] truncate sm:max-w-[24ch]">{label}</span>
          {isEnvLocked && <Lock className="size-3 text-muted-foreground" />}
        </button>
      </TooltipTrigger>
      <TooltipContent side="bottom" className="max-w-[28rem] whitespace-pre-line break-all font-mono">
        {tooltipBody}
      </TooltipContent>
    </Tooltip>
  );
}
