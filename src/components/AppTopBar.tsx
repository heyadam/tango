'use client';

import {
  Code2,
  Folder,
  FolderOpen,
  Lock,
  PanelLeftClose,
  PanelLeftOpen,
  Smartphone,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
import TangoLogo from '@/components/TangoLogo';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import {
  TERMINAL_AGENTS,
  TERMINAL_AGENT_IDS,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { cn } from '@/lib/utils';

type WorkspaceSource = 'env' | 'persisted' | 'unset';

type Props = {
  terminalOpen: boolean;
  simOpen: boolean;
  terminalAgent: TerminalAgentId;
  workspaceName: string | null;
  workspacePath: string | null;
  workspaceSource: WorkspaceSource;
  onOpenWorkspaceDialog: () => void;
  onToggleTerminal: () => void;
  onToggleSim: () => void;
  onTerminalAgentChange: (agent: TerminalAgentId) => void;
};

export default function AppTopBar({
  terminalOpen,
  simOpen,
  terminalAgent,
  workspaceName,
  workspacePath,
  workspaceSource,
  onOpenWorkspaceDialog,
  onToggleTerminal,
  onToggleSim,
  onTerminalAgentChange,
}: Props) {
  const activeAgent = TERMINAL_AGENTS[terminalAgent];

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
        <Separator
          orientation="vertical"
          className="mx-1 data-[orientation=vertical]:h-4"
        />
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={onToggleTerminal}
              aria-label={
                terminalOpen ? 'Hide agent sidebar' : 'Show agent sidebar'
              }
              aria-pressed={terminalOpen}
              className="text-muted-foreground hover:text-foreground"
            >
              {terminalOpen ? (
                <PanelLeftClose className="size-4" />
              ) : (
                <PanelLeftOpen className="size-4" />
              )}
            </Button>
          </TooltipTrigger>
          <TooltipContent side="bottom">
            {terminalOpen ? 'Hide agent sidebar' : 'Show agent sidebar'}
          </TooltipContent>
        </Tooltip>
        <TerminalAgentSwitch
          value={terminalAgent}
          onChange={onTerminalAgentChange}
        />
        <div className="hidden items-center gap-1.5 text-xs font-medium text-foreground sm:flex">
          <Code2 className="size-3.5 text-muted-foreground" />
          <span>{activeAgent.label}</span>
        </div>
      </div>

      <div className="flex items-center justify-end gap-2">
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

function TerminalAgentSwitch({
  value,
  onChange,
}: {
  value: TerminalAgentId;
  onChange: (agent: TerminalAgentId) => void;
}) {
  return (
    <div
      role="group"
      aria-label="Terminal agent"
      className="hidden h-8 items-center rounded-md border border-border bg-muted p-0.5 sm:flex"
    >
      {TERMINAL_AGENT_IDS.map((id) => {
        const active = id === value;
        const meta = TERMINAL_AGENTS[id];
        return (
          <button
            key={id}
            type="button"
            onClick={() => onChange(id)}
            aria-pressed={active}
            className={cn(
              'h-7 min-w-16 rounded px-2.5 text-xs font-medium text-muted-foreground transition-colors',
              active && 'bg-background text-foreground shadow-sm',
              !active && 'hover:text-foreground',
            )}
          >
            {meta.shortLabel}
          </button>
        );
      })}
    </div>
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
