'use client';

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from 'react';
import { Folder, FolderOpen, FolderSearch, History, Loader2, X } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { recentProjects, type RecentProject } from '@/lib/recentProjects';
import { workspaceBus } from '@/lib/workspaceBus';

type WorkspaceCurrent = {
  path: string | null;
  name: string | null;
  source: 'env' | 'persisted' | 'unset';
};

type SelectErrorEntry = { file: string; reason: string };

type SelectResponse =
  | { ok: true; path: string; name: string; errors?: SelectErrorEntry[] }
  | { ok: false; code: 'env_locked' }
  | { ok: false; code: 'invalid_path'; reason: string }
  | { ok: false; code: 'ensure_failed'; reason: string };

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  current: WorkspaceCurrent;
  // When true, the picker is the first thing the user sees on a fresh boot —
  // it should not be dismissable (no close button, ESC ignored).
  blocking?: boolean;
};

type StateMachine =
  | { kind: 'idle' }
  | { kind: 'browsing' }
  | { kind: 'ensuring' }
  | { kind: 'error'; reason: string }
  | { kind: 'softWarnings'; warnings: SelectErrorEntry[]; path: string; name: string };

type BrowseResponse =
  | { ok: true; path: string }
  | { ok: false; code: 'cancelled' }
  | { ok: false; code: 'unsupported_platform'; platform: string }
  | { ok: false; code: 'error'; reason: string };

const TRUNCATE = 60;

function truncatePath(p: string): string {
  if (p.length <= TRUNCATE) return p;
  return '…' + p.slice(p.length - TRUNCATE + 1);
}

export default function WorkspaceDialog({
  open,
  onOpenChange,
  current,
  blocking = false,
}: Props) {
  const envLocked = current.source === 'env';
  const [pathInput, setPathInput] = useState('');
  const [recents, setRecents] = useState<RecentProject[]>([]);
  const [state, setState] = useState<StateMachine>({ kind: 'idle' });
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (open) {
      setRecents(recentProjects.list());
      setPathInput(current.path ?? '');
      setState({ kind: 'idle' });
      // Defer focus so Radix has time to mount the dialog.
      const t = setTimeout(() => inputRef.current?.focus(), 50);
      return () => clearTimeout(t);
    }
  }, [open, current.path]);

  const submit = useCallback(
    async (rawPath: string) => {
      const path = rawPath.trim();
      if (!path) {
        setState({ kind: 'error', reason: 'Pick a folder or paste a path.' });
        return;
      }
      setState({ kind: 'ensuring' });
      let res: Response;
      try {
        res = await fetch('/api/workspace/select', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ path }),
        });
      } catch (err) {
        setState({
          kind: 'error',
          reason:
            err instanceof Error
              ? `Network error: ${err.message}`
              : 'Network error contacting the server.',
        });
        return;
      }
      let body: SelectResponse;
      try {
        body = (await res.json()) as SelectResponse;
      } catch {
        setState({ kind: 'error', reason: `Server error (HTTP ${res.status}).` });
        return;
      }
      if (!body.ok) {
        if (body.code === 'env_locked') {
          setState({
            kind: 'error',
            reason: 'Workspace is pinned by TANGO_WORKSPACE — unset and reload to change it.',
          });
          return;
        }
        setState({ kind: 'error', reason: body.reason });
        return;
      }

      // Success. Update recents, broadcast to the rest of the app, then close
      // (or surface soft warnings first).
      recentProjects.add({ path: body.path, name: body.name });
      workspaceBus.emit({ path: body.path, name: body.name });

      if (body.errors && body.errors.length > 0) {
        setState({
          kind: 'softWarnings',
          warnings: body.errors,
          path: body.path,
          name: body.name,
        });
        return;
      }
      onOpenChange(false);
    },
    [onOpenChange],
  );

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (envLocked) return;
    void submit(pathInput);
  };

  const onPickRecent = (item: RecentProject) => {
    setPathInput(item.path);
    void submit(item.path);
  };

  const onBrowse = useCallback(async () => {
    setState({ kind: 'browsing' });
    let res: Response;
    try {
      res = await fetch('/api/workspace/browse', { method: 'POST' });
    } catch (err) {
      setState({
        kind: 'error',
        reason:
          err instanceof Error
            ? `Network error: ${err.message}`
            : 'Network error opening folder picker.',
      });
      return;
    }
    let body: BrowseResponse;
    try {
      body = (await res.json()) as BrowseResponse;
    } catch {
      setState({
        kind: 'error',
        reason: `Server error opening folder picker (HTTP ${res.status}).`,
      });
      return;
    }
    if (!body.ok) {
      if (body.code === 'cancelled') {
        // User dismissed the system dialog — silently return to idle, no
        // error noise.
        setState({ kind: 'idle' });
        return;
      }
      if (body.code === 'unsupported_platform') {
        setState({
          kind: 'error',
          reason: `Native folder picker is only available on macOS (running on ${body.platform}). Type the path instead.`,
        });
        return;
      }
      setState({ kind: 'error', reason: body.reason });
      return;
    }
    setPathInput(body.path);
    // Auto-submit so picking through Finder is one click, not two.
    void submit(body.path);
  }, [submit]);

  const onForgetRecent = (item: RecentProject) => {
    setRecents(recentProjects.remove(item.path));
  };

  const onAcceptWarnings = () => {
    onOpenChange(false);
  };

  const description = useMemo(() => {
    if (envLocked) {
      return 'Workspace is pinned by the TANGO_WORKSPACE environment variable. Unset it and reload to change folders.';
    }
    return 'Tango will set up MCP and Claude tooling in this folder. Your existing CLAUDE.md and .mcp.json are preserved — we only manage a small sentinel block.';
  }, [envLocked]);

  // Blocking dialogs ignore Radix's "user wants to close" signals (escape,
  // overlay click, X button). Non-blocking dialogs forward them through.
  const handleOpenChange = (next: boolean) => {
    if (blocking && !next) return;
    onOpenChange(next);
  };

  const isBusy = state.kind === 'ensuring' || state.kind === 'browsing';

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent
        className="sm:max-w-[560px]"
        showCloseButton={!blocking}
        onEscapeKeyDown={(e) => {
          if (blocking) e.preventDefault();
        }}
        onPointerDownOutside={(e) => {
          if (blocking) e.preventDefault();
        }}
        onInteractOutside={(e) => {
          if (blocking) e.preventDefault();
        }}
      >
        <DialogHeader>
          <DialogTitle>Pick a project folder</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>

        {envLocked && (
          <div className="rounded-md border border-orange-300 bg-orange-100 p-3 text-xs text-orange-900">
            <code className="font-mono">TANGO_WORKSPACE</code> is set to{' '}
            <code className="font-mono break-all">{current.path}</code>. The picker is read-only.
          </div>
        )}

        {state.kind === 'softWarnings' ? (
          <SoftWarningsView
            warnings={state.warnings}
            path={state.path}
            onAccept={onAcceptWarnings}
          />
        ) : (
          <>
            {recents.length > 0 && (
              <div className="space-y-1">
                <div className="flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  <History className="size-3" />
                  Recent
                </div>
                <ul className="space-y-1">
                  {recents.map((item) => (
                    <li key={item.path} className="group flex items-center gap-1">
                      <button
                        type="button"
                        disabled={envLocked || isBusy}
                        onClick={() => onPickRecent(item)}
                        className="flex flex-1 items-center gap-2 rounded-md border border-border bg-card/60 px-3 py-2 text-left text-sm hover:border-foreground/30 hover:bg-card disabled:cursor-not-allowed disabled:opacity-50"
                      >
                        <Folder className="size-4 shrink-0 text-muted-foreground" />
                        <div className="min-w-0 flex-1">
                          <div className="truncate font-medium">{item.name}</div>
                          <div className="truncate font-mono text-xs text-muted-foreground">
                            {truncatePath(item.path)}
                          </div>
                        </div>
                      </button>
                      <button
                        type="button"
                        aria-label={`Forget ${item.name}`}
                        onClick={() => onForgetRecent(item)}
                        disabled={isBusy}
                        className="flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground opacity-0 transition-opacity hover:bg-accent hover:text-foreground group-hover:opacity-100 disabled:opacity-30"
                      >
                        <X className="size-3.5" />
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            )}

            <Button
              type="button"
              variant="outline"
              onClick={onBrowse}
              disabled={envLocked || isBusy}
              className="w-full justify-center"
            >
              {state.kind === 'browsing' ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Waiting for Finder…
                </>
              ) : (
                <>
                  <FolderSearch className="size-4" />
                  Choose folder…
                </>
              )}
            </Button>

            <div className="flex items-center gap-3 text-[10px] uppercase tracking-wider text-muted-foreground/60">
              <span className="h-px flex-1 bg-border" />
              or paste a path
              <span className="h-px flex-1 bg-border" />
            </div>

            <form onSubmit={onSubmit} className="space-y-2">
              <div className="flex gap-2">
                <Input
                  ref={inputRef}
                  type="text"
                  spellCheck={false}
                  autoCorrect="off"
                  autoCapitalize="off"
                  placeholder="/Users/you/dev/your-project"
                  value={pathInput}
                  onChange={(e) => {
                    setPathInput(e.target.value);
                    if (state.kind === 'error') setState({ kind: 'idle' });
                  }}
                  disabled={envLocked || isBusy}
                  aria-invalid={state.kind === 'error'}
                  className="font-mono text-sm"
                />
                <Button
                  type="submit"
                  disabled={envLocked || isBusy || pathInput.trim() === ''}
                  className="shrink-0"
                >
                  {state.kind === 'ensuring' ? (
                    <>
                      <Loader2 className="size-4 animate-spin" />
                      Setting up
                    </>
                  ) : (
                    <>
                      <FolderOpen className="size-4" />
                      Open
                    </>
                  )}
                </Button>
              </div>
              <p className="text-xs text-muted-foreground">
                Absolute path. <code className="font-mono">~</code> is expanded.
              </p>

              {state.kind === 'error' && (
                <div className="rounded-md border border-pink-300 bg-pink-100 p-3 text-xs text-pink-900">
                  {state.reason}
                </div>
              )}
            </form>

            <details className="rounded-md border border-border bg-card/40 p-3 text-xs text-muted-foreground">
              <summary className="cursor-pointer font-medium text-foreground/90">
                What tango will write
              </summary>
              <ul className="mt-2 space-y-1 font-mono">
                <li>
                  <span className="text-muted-foreground">overwrite&nbsp;</span>
                  .claude/tango.md
                </li>
                <li>
                  <span className="text-muted-foreground">merge&nbsp;&nbsp;&nbsp;&nbsp;</span>
                  CLAUDE.md
                  <span className="text-muted-foreground"> (3-line sentinel block)</span>
                </li>
                <li>
                  <span className="text-muted-foreground">merge&nbsp;&nbsp;&nbsp;&nbsp;</span>
                  .mcp.json
                  <span className="text-muted-foreground"> (under mcpServers.tango-canvas)</span>
                </li>
                <li>
                  <span className="text-muted-foreground">merge&nbsp;&nbsp;&nbsp;&nbsp;</span>
                  .claude/settings.json
                </li>
                <li>
                  <span className="text-muted-foreground">mkdir&nbsp;&nbsp;&nbsp;&nbsp;</span>
                  design-scratch/
                </li>
              </ul>
            </details>
          </>
        )}

        {!blocking && state.kind !== 'softWarnings' && (
          <DialogFooter>
            <Button
              variant="ghost"
              onClick={() => onOpenChange(false)}
              disabled={isBusy}
            >
              Cancel
            </Button>
          </DialogFooter>
        )}
      </DialogContent>
    </Dialog>
  );
}

function SoftWarningsView({
  warnings,
  path,
  onAccept,
}: {
  warnings: SelectErrorEntry[];
  path: string;
  onAccept: () => void;
}) {
  return (
    <div className="space-y-3">
      <div className="rounded-md border border-orange-300 bg-orange-100 p-3 text-xs text-orange-900">
        <p className="font-medium">Workspace is set, with warnings.</p>
        <p className="mt-1 text-orange-800/90">
          We couldn&apos;t merge some managed files in{' '}
          <code className="font-mono">{path}</code>. Tango is usable; the listed files were
          left untouched and the affected features may not work until you fix or remove them.
        </p>
      </div>
      <ul className="space-y-1 text-xs">
        {warnings.map((w) => (
          <li
            key={w.file}
            className="rounded-md border border-border bg-card/40 p-2"
          >
            <code className="font-mono text-foreground/90">{w.file}</code>
            <div className="text-muted-foreground">{w.reason}</div>
          </li>
        ))}
      </ul>
      <DialogFooter>
        <Button onClick={onAccept}>Continue</Button>
      </DialogFooter>
    </div>
  );
}
