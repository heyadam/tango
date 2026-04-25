'use client';

import {
  Code2,
  Folder,
  FolderOpen,
  LayoutDashboard,
  Lock,
  PanelLeftClose,
  PanelLeftOpen,
  PanelRightClose,
  PanelRightOpen,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import { cn } from '@/lib/utils';

type WorkspaceMode = 'sketch' | 'moodboard' | 'brand';
type WorkspaceSource = 'env' | 'persisted' | 'unset';

type Props = {
  agentOpen: boolean;
  claudeOpen: boolean;
  mode: WorkspaceMode;
  workspaceName: string | null;
  workspacePath: string | null;
  workspaceSource: WorkspaceSource;
  onOpenWorkspaceDialog: () => void;
  onToggleAgent: () => void;
  onToggleClaude: () => void;
  onModeChange: (mode: WorkspaceMode) => void;
};

const modes: Array<{ value: WorkspaceMode; label: string }> = [
  { value: 'sketch', label: 'Sketch' },
  { value: 'moodboard', label: 'Moodboard' },
  { value: 'brand', label: 'Brand' },
];

export default function AppTopBar({
  agentOpen,
  claudeOpen,
  mode,
  workspaceName,
  workspacePath,
  workspaceSource,
  onOpenWorkspaceDialog,
  onToggleAgent,
  onToggleClaude,
  onModeChange,
}: Props) {
  return (
    <header className="grid h-12 shrink-0 grid-cols-[1fr_auto_1fr] items-center border-b border-neutral-800 bg-neutral-950 px-2">
      <div className="flex items-center gap-2">
        <Button
          variant="ghost"
          size="icon-sm"
          onClick={onToggleAgent}
          aria-label={agentOpen ? 'Hide agent sidebar' : 'Show agent sidebar'}
          aria-pressed={agentOpen}
          className="text-neutral-400 hover:text-neutral-100"
        >
          {agentOpen ? (
            <PanelLeftClose className="size-4" />
          ) : (
            <PanelLeftOpen className="size-4" />
          )}
        </Button>
        <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-300">
          <LayoutDashboard className="size-3.5 text-neutral-500" />
          <span>Tango</span>
        </div>
        <span className="text-neutral-700">/</span>
        <WorkspacePill
          name={workspaceName}
          path={workspacePath}
          source={workspaceSource}
          onClick={onOpenWorkspaceDialog}
        />
      </div>

      <div
        role="tablist"
        aria-label="Workspace mode"
        className="flex h-8 items-center rounded-md border border-neutral-800 bg-neutral-900 p-0.5"
      >
        {modes.map((item) => (
          <button
            key={item.value}
            type="button"
            role="tab"
            aria-selected={mode === item.value}
            onClick={() => onModeChange(item.value)}
            className={cn(
              'h-7 min-w-20 rounded px-2 text-xs font-medium text-neutral-400 transition-colors hover:text-neutral-100 sm:min-w-24 sm:px-3',
              mode === item.value &&
                'bg-neutral-100 text-neutral-950 shadow-sm hover:text-neutral-950',
            )}
          >
            {item.label}
          </button>
        ))}
      </div>

      <div className="flex items-center justify-end gap-2">
        <div className="hidden items-center gap-1.5 text-xs font-medium text-neutral-300 sm:flex">
          <Code2 className="size-3.5 text-neutral-500" />
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
          className="text-neutral-400 hover:text-neutral-100"
        >
          {claudeOpen ? (
            <PanelRightClose className="size-4" />
          ) : (
            <PanelRightOpen className="size-4" />
          )}
        </Button>
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
              ? 'border-amber-700/40 bg-amber-900/20 text-amber-200 hover:border-amber-600/60 hover:bg-amber-900/30'
              : 'border-neutral-800 bg-neutral-900 text-neutral-200 hover:border-neutral-700 hover:bg-neutral-800',
          )}
        >
          {isUnset ? (
            <FolderOpen className="size-3.5 text-amber-300" />
          ) : (
            <Folder className="size-3.5 text-neutral-400" />
          )}
          <span className="max-w-[16ch] truncate sm:max-w-[24ch]">{label}</span>
          {isEnvLocked && <Lock className="size-3 text-neutral-500" />}
        </button>
      </TooltipTrigger>
      <TooltipContent side="bottom" className="max-w-[28rem] whitespace-pre-line break-all font-mono">
        {tooltipBody}
      </TooltipContent>
    </Tooltip>
  );
}
