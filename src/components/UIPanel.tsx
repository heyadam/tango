'use client';

// The design-canvas panel (center, right of the agent sidebar): an SSR-safe
// shell around the design canvas. Owns the
// /ws/ui-mock socket and dynamic-imports UIMockCanvas (react-moveable touches
// `window` at module load).
//
// The Send action packages the current spec into a markdown handoff prompt
// and submits it to the active terminal agent via terminalBus. The spec
// JSON is the source of truth for what the user wants — the agent reads it and
// translates the absolute-positioned design into responsive Tailwind in the
// production codebase. The user's drag/resize tweaks are visible to the agent
// as updated coords on its next `get_ui_mock` read.

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import {
  FileDown,
  Frame,
  PanelRight,
  Play,
  RefreshCw,
  Rocket,
  Send,
  Trash2,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from './ui/button';
import PanelHeader from './PanelHeader';
import { uiMockBus } from '@/lib/uiMockBus';
import { uiMockStore } from '@/lib/uiMockStore';
import { EMPTY_SPEC, type UISpec } from '@/lib/uiMockProtocol';
import { workspaceBus } from '@/lib/workspaceBus';
import { openWS } from '@/lib/wsClient';
import { terminalBus } from '@/lib/terminalBus';
import {
  TERMINAL_AGENTS,
  type TerminalAgentId,
} from '@/lib/terminalAgent';

const UIMockCanvas = dynamic(() => import('./UIMockCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-background" />,
});

// Warm the canvas chunk in parallel with the workspace fetch instead of after
// mount. The dynamic() above stays as the SSR boundary (react-moveable touches
// `window` at module load).
if (typeof window !== 'undefined') {
  void import('./UIMockCanvas');
}

// Subtracted from the wrapper rect when reporting "viewport" to Claude so
// the size is the largest frame that fits *without scrolling*. Mirrors
// UIMockCanvas's inner `gap-20 p-10` (40px outer padding each side → 80px
// per axis) plus each screen's title row above the frame (text-xs ≈ 16px
// + gap-2 = 8px → ~24px on top, none on bottom). The title row now also
// carries a click-to-activate affordance and an inline file chip — it MUST
// stay single-line; if it ever grows taller, FRAME_INSET_Y (104) changes in
// lockstep. If those classes change in UIMockCanvas, update these here too.
// The reported size is physical px and intentionally ignores the canvas
// camera zoom — frames should default to a size that fits at 100%.
const FRAME_INSET_X = 80;
const FRAME_INSET_Y = 104;

type LoadState =
  | { status: 'loading' }
  | { status: 'ready'; initialSpec: UISpec };

type Props = {
  terminalAgent: TerminalAgentId;
};

export default function UIPanel({ terminalAgent }: Props) {
  const terminalAgentMeta = TERMINAL_AGENTS[terminalAgent];
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });
  // Right design sidebar (layers tree + inspector). UIPanel owns the layout
  // (the canvas's viewport measurement must exclude the sidebar) and hands
  // the container element down; UIMockCanvas portals the content into it —
  // its spec/selection state stays where it lives.
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [sidebarEl, setSidebarEl] = useState<HTMLDivElement | null>(null);
  const sidebarRef = useCallback((el: HTMLDivElement | null) => {
    setSidebarEl(el);
  }, []);
  // Bumping this remounts UIMockCanvas (and re-runs the WS effect) so a
  // workspace switch starts from a clean slate.
  const [generation, setGeneration] = useState(0);
  const [sendBusy, setSendBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  // Live screen count — drives the toolbar's "X screens" text and the
  // disabled state of the Send / Clear buttons. Has to be state (not just a
  // ref) because the toolbar is rendered by this component, not the canvas.
  const [screenCount, setScreenCount] = useState(0);

  // Latest spec — kept in a ref so Send / Clear don't have to
  // re-render to read it. Updated on every server `set` and every local
  // snapshot.
  const specRef = useRef<UISpec>(EMPTY_SPEC);

  // Container we hand to ResizeObserver — its rect is what frames render
  // into, so it's the "viewport" Claude wants when defaulting frame sizes.
  const viewportRef = useRef<HTMLDivElement | null>(null);
  // The live WS, exposed to the viewport effect (which lives outside the
  // socket-owning effect) via this ref so a resize during a workspace switch
  // doesn't try to send through a closed socket.
  const wsRef = useRef<WebSocket | null>(null);
  // Last-sent {w,h} so we don't spam identical frames after no-op resizes.
  const lastSentViewport = useRef<{ w: number; h: number } | null>(null);
  // Last reported working screen — resent on (re)connect so the preview host
  // shows the right screen after a socket bounce.
  const lastActiveScreen = useRef<string | null>(null);
  // Header caption.
  const [viewport, setViewport] = useState<{ w: number; h: number } | null>(
    null,
  );

  // On workspace switch: drop local cache and remount.
  useEffect(() => {
    return workspaceBus.subscribe(() => {
      uiMockStore.clear();
      uiMockBus._resetForWorkspaceSwitch();
      specRef.current = EMPTY_SPEC;
      setScreenCount(0);
      setLoad({ status: 'loading' });
      // Server-side viewport got reset; force a resend on the new socket
      // even if our measured size didn't change.
      lastSentViewport.current = null;
      setViewport(null);
      setGeneration((g) => g + 1);
    });
  }, []);

  // Hydrate the initial spec from localStorage so a refresh keeps the user's
  // last view. The server's `set` on WS connect will replace this if the
  // server's cache differs.
  useEffect(() => {
    const initial = uiMockStore.load();
    specRef.current = initial;
    setScreenCount(initial.screens.length);
    setLoad({ status: 'ready', initialSpec: initial });
  }, [generation]);

  const persist = useCallback((spec: UISpec) => {
    specRef.current = spec;
    setScreenCount(spec.screens.length);
    uiMockStore.save(spec);
  }, []);

  // Working-screen reports from the canvas → server (drives the preview-host
  // app's screen selection). Canvas already dedupes consecutive repeats.
  const handleActiveScreen = useCallback((screenId: string) => {
    lastActiveScreen.current = screenId;
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify({ type: 'active_screen', screenId }));
      } catch {
        // socket dying — the open handler will resend on reconnect
      }
    }
  }, []);

  // Open the WS bridge: outbound snapshots flow through uiMockBus from the
  // canvas; inbound apply messages go to the canvas via the same bus.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const ws = openWS('/ws/ui-mock');
    wsRef.current = ws;

    const offSnapshot = uiMockBus._onSnapshot((spec) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: 'snapshot', spec }));
      } catch {
        // socket dying — cleanup runs on close
      }
    });

    // Once the socket opens, prime the server with whatever viewport size
    // we already measured — the ResizeObserver fires before openWS returns
    // a connected socket, so the first measurement would otherwise be lost.
    const sendCurrentViewport = () => {
      const last = lastSentViewport.current;
      if (last) {
        try {
          ws.send(JSON.stringify({ type: 'viewport', w: last.w, h: last.h }));
        } catch {
          // socket dying — cleanup runs on close
        }
      }
      if (lastActiveScreen.current) {
        try {
          ws.send(
            JSON.stringify({
              type: 'active_screen',
              screenId: lastActiveScreen.current,
            }),
          );
        } catch {
          // socket dying — cleanup runs on close
        }
      }
    };
    if (ws.readyState === WebSocket.OPEN) {
      sendCurrentViewport();
    } else {
      ws.addEventListener('open', sendCurrentViewport, { once: true });
    }

    ws.addEventListener('message', (ev) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : '');
      } catch {
        return;
      }
      if (
        !parsed ||
        typeof parsed !== 'object' ||
        !('type' in parsed)
      ) {
        return;
      }
      const msg = parsed as { type: string };
      if (msg.type === 'set') {
        const setMsg = parsed as { type: 'set'; spec: UISpec };
        specRef.current = setMsg.spec;
        setScreenCount(setMsg.spec.screens.length);
        uiMockStore.save(setMsg.spec);
        uiMockBus._emitApply(setMsg);
      } else if (msg.type === 'append_screen') {
        const appMsg = parsed as {
          type: 'append_screen';
          screen: UISpec['screens'][number];
        };
        specRef.current = {
          ...specRef.current,
          screens: [...specRef.current.screens, appMsg.screen],
        };
        setScreenCount(specRef.current.screens.length);
        uiMockStore.save(specRef.current);
        uiMockBus._emitApply(appMsg);
      }
    });

    return () => {
      offSnapshot();
      wsRef.current = null;
      try {
        ws.close();
      } catch {
        // already closed
      }
    };
  }, [generation]);

  // Watch the panel's render area and ship viewport size up the WS on every
  // (debounced) resize. Trailing-edge only — Claude only ever needs the
  // latest size. Round to integers so noisy subpixel measurements don't
  // produce a flood of identical-after-rounding sends.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const el = viewportRef.current;
    if (!el) return;

    let timer: number | null = null;
    const measureAndSend = () => {
      const rect = el.getBoundingClientRect();
      const w = Math.max(0, Math.round(rect.width) - FRAME_INSET_X);
      const h = Math.max(0, Math.round(rect.height) - FRAME_INSET_Y);
      if (w <= 0 || h <= 0) return;
      const prev = lastSentViewport.current;
      if (prev && prev.w === w && prev.h === h) return;
      lastSentViewport.current = { w, h };
      setViewport({ w, h });
      const ws = wsRef.current;
      if (ws && ws.readyState === WebSocket.OPEN) {
        try {
          ws.send(JSON.stringify({ type: 'viewport', w, h }));
        } catch {
          // socket dying — the open handler will resend on reconnect
        }
      }
    };

    measureAndSend();

    const ro = new ResizeObserver(() => {
      if (timer != null) window.clearTimeout(timer);
      timer = window.setTimeout(measureAndSend, 150);
    });
    ro.observe(el);

    return () => {
      ro.disconnect();
      if (timer != null) window.clearTimeout(timer);
    };
  }, [generation]);

  const sendToClaude = useCallback(async () => {
    if (sendBusy) return;
    const spec = specRef.current;
    if (!spec.screens || spec.screens.length === 0) {
      setStatus(
        `Canvas is empty — ask ${terminalAgentMeta.shortLabel} to draft a design first.`,
      );
      return;
    }
    setSendBusy(true);
    setStatus(null);
    try {
      const handoff = buildHandoffPrompt(spec);
      terminalBus.submitToTerminal(handoff);
      setStatus(
        `Sent ${spec.screens.length} screen${spec.screens.length === 1 ? '' : 's'} to ${terminalAgentMeta.shortLabel}.`,
      );
    } catch (err) {
      setStatus(
        `Send failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      setSendBusy(false);
    }
  }, [sendBusy, terminalAgentMeta.shortLabel]);

  // Live preview: the preview-host app on the simulator renders the design
  // over /ws/preview. The dot tracks the lifecycle: gray = stopped, amber =
  // building/launching, green = running + connected, red = running but its
  // socket dropped (relaunch usually fixes it).
  type PreviewUiState = 'stopped' | 'busy' | 'connected' | 'disconnected' | 'error';
  const [previewState, setPreviewState] = useState<PreviewUiState>('stopped');
  const [previewBusy, setPreviewBusy] = useState(false);
  // The poll callback reads the latest state via a ref so the effect doesn't
  // re-subscribe on every state change.
  const previewStateRef = useRef<PreviewUiState>('stopped');
  previewStateRef.current = previewState;

  useEffect(() => {
    let cancelled = false;
    let timer: number | null = null;
    const tick = async () => {
      try {
        const res = await fetch('/api/preview/status', { cache: 'no-store' });
        const s = (await res.json()) as { phase: string; connected?: boolean };
        if (cancelled) return;
        if (s.phase === 'running') {
          setPreviewState(s.connected ? 'connected' : 'disconnected');
        } else if (s.phase === 'error') {
          setPreviewState('error');
        } else if (s.phase === 'stopped') {
          setPreviewState('stopped');
        } else {
          setPreviewState('busy');
        }
      } catch {
        if (!cancelled) setPreviewState('stopped');
      }
      if (cancelled) return;
      timer = window.setTimeout(tick, previewStateRef.current === 'busy' ? 1000 : 5000);
    };
    void tick();
    return () => {
      cancelled = true;
      if (timer != null) window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const startPreview = useCallback(async () => {
    if (previewBusy) return;
    setPreviewBusy(true);
    setStatus(
      previewStateRef.current === 'connected'
        ? 'Bringing the preview to the foreground…'
        : 'Starting preview… first run builds the preview app (~30–60s).',
    );
    try {
      const res = await fetch('/api/preview/start', { method: 'POST' });
      if (!res.ok && res.status !== 409) {
        const body = (await res.json().catch(() => ({}))) as { reason?: string };
        setStatus(`Preview failed to start: ${body.reason ?? `HTTP ${res.status}`}`);
        return;
      }
      setPreviewState('busy');
      // Poll until it settles so the status strip tells the story.
      for (;;) {
        await new Promise((r) => setTimeout(r, 1000));
        if (!mountedRef.current) return;
        const s = (await (
          await fetch('/api/preview/status', { cache: 'no-store' })
        ).json()) as { phase: string; connected?: boolean; message?: string };
        if (s.phase === 'running') {
          setPreviewState(s.connected ? 'connected' : 'disconnected');
          setStatus(
            s.connected
              ? 'Preview live — canvas edits now mirror to the simulator.'
              : 'Preview app launched; waiting for it to connect…',
          );
          return;
        }
        if (s.phase === 'error') {
          setPreviewState('error');
          setStatus(`Preview failed: ${s.message ?? 'unknown error'}`);
          return;
        }
      }
    } catch (err) {
      setStatus(
        `Preview failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      if (mountedRef.current) setPreviewBusy(false);
    }
  }, [previewBusy]);

  // Export & Run: POST kicks the server-side pipeline (codegen → xcodebuild →
  // install → launch), then poll the phase once a second — matches the
  // SimulatorPanel polling pattern; phases are coarse and build-dominated, so
  // SSE would buy nothing.
  const [exporting, setExporting] = useState(false);
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const exportAndRun = useCallback(async () => {
    if (exporting) return;
    setExporting(true);
    setStatus('Exporting…');
    const startedAt = Date.now();
    try {
      const kick = await fetch('/api/ios/export-run', { method: 'POST' });
      if (!kick.ok) {
        const body = (await kick.json().catch(() => ({}))) as {
          reason?: string;
        };
        setStatus(`Export blocked: ${body.reason ?? `HTTP ${kick.status}`}`);
        return;
      }
      for (;;) {
        await new Promise((r) => setTimeout(r, 1000));
        if (!mountedRef.current) return;
        const res = await fetch('/api/ios/export-run', { cache: 'no-store' });
        const s = (await res.json()) as {
          phase: string;
          stage?: string;
          message?: string;
          errors?: string[];
          bundleId?: string;
          durationMs?: number;
          inclusion?: string;
          embedded?: boolean;
        };
        if (s.phase === 'done') {
          const secs = ((s.durationMs ?? 0) / 1000).toFixed(1);
          const manual =
            s.inclusion === 'manual-add-required'
              ? ' — one-time setup: drag TangoGenerated/ into your Xcode target'
              : '';
          if (s.embedded === false) {
            // Built and launched, but no user Swift shows the generated views
            // — without this warning the launch looks like a silent no-op.
            setStatus(
              `Launched in ${secs}s — but the app doesn't show the design yet: add TangoGeneratedRootView() to your app (e.g. in place of ContentView()), or ask ${terminalAgentMeta.shortLabel} to wire it up.${manual}`,
            );
            return;
          }
          setStatus(`Launched ${s.bundleId ?? 'app'} in ${secs}s.${manual}`);
          return;
        }
        if (s.phase === 'error') {
          const detail = s.errors && s.errors.length > 0 ? ` — ${s.errors[0]}` : '';
          setStatus(`Export failed (${s.stage}): ${s.message}${detail}`);
          return;
        }
        if (s.phase === 'idle') {
          setStatus('Export ended unexpectedly.');
          return;
        }
        const labels: Record<string, string> = {
          generating: 'Generating SwiftUI',
          writing: 'Writing files',
          building: 'Building',
          installing: 'Installing',
          launching: 'Launching',
        };
        setStatus(
          `${labels[s.phase] ?? s.phase}… ${Math.round((Date.now() - startedAt) / 1000)}s`,
        );
      }
    } catch (err) {
      setStatus(
        `Export failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      if (mountedRef.current) setExporting(false);
    }
  }, [exporting, terminalAgentMeta.shortLabel]);

  // Import from code: kick the server-side fast-import engine (a dedicated
  // direct-API loop with the SwiftUI→UINode rules baked in — see
  // src/server/uiImport.ts) and poll progress. Still agent-mediated by design
  // — parsing arbitrary hand-written SwiftUI deterministically is brittle;
  // the deterministic direction is export (Export & Run). The canvas updates
  // live over /ws/ui-mock as each screen lands.
  const [importing, setImporting] = useState(false);
  const importFromCode = useCallback(async () => {
    if (importing) return;
    setImporting(true);
    setStatus('Importing…');
    try {
      const kick = await fetch('/api/ui/import', { method: 'POST' });
      if (!kick.ok) {
        const body = (await kick.json().catch(() => ({}))) as {
          reason?: string;
        };
        setStatus(`Import blocked: ${body.reason ?? `HTTP ${kick.status}`}`);
        return;
      }
      for (;;) {
        await new Promise((r) => setTimeout(r, 700));
        if (!mountedRef.current) return;
        const res = await fetch('/api/ui/import', { cache: 'no-store' });
        const s = (await res.json()) as {
          phase: string;
          filesRead?: number;
          screensImported?: number;
          durationMs?: number;
          message?: string;
        };
        if (s.phase === 'done') {
          const secs = ((s.durationMs ?? 0) / 1000).toFixed(1);
          setStatus(
            `Imported ${s.screensImported} screen${s.screensImported === 1 ? '' : 's'} in ${secs}s.`,
          );
          return;
        }
        if (s.phase === 'error') {
          setStatus(`Import failed: ${s.message ?? 'unknown error'}`);
          return;
        }
        if (s.phase === 'idle') {
          setStatus('Import ended unexpectedly.');
          return;
        }
        setStatus(
          `Importing… ${s.filesRead ?? 0} file${(s.filesRead ?? 0) === 1 ? '' : 's'} read · ${s.screensImported ?? 0} screen${(s.screensImported ?? 0) === 1 ? '' : 's'}`,
        );
      }
    } catch (err) {
      setStatus(
        `Import failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      if (mountedRef.current) setImporting(false);
    }
  }, [importing]);

  const clearMock = useCallback(() => {
    // Local clear: emit an empty snapshot so the server cache matches and
    // any open browsers see the same state on refresh. We don't call MCP from
    // here — clear_ui_mock is for Claude.
    const empty: UISpec = { screens: [] };
    specRef.current = empty;
    setScreenCount(0);
    uiMockStore.save(empty);
    uiMockBus._emitApply({ type: 'set', spec: empty });
    uiMockBus._emitSnapshot(empty);
    setStatus('Cleared.');
  }, []);

  return (
    <div className="flex h-full min-h-0 flex-col bg-background text-foreground">
      <PanelHeader
        leftSlot={
          <>
            <Frame className="size-3.5 text-panel-header-foreground/70" />
            <span>Design</span>
            {load.status === 'ready' && screenCount > 0 && (
              <span className="text-xs text-panel-header-foreground/80">
                {screenCount} screen{screenCount === 1 ? '' : 's'}
              </span>
            )}
            {viewport && (
              <span
                className="font-mono text-[10px] text-panel-header-foreground/60"
                title="Default frame size for new screens"
              >
                {viewport.w}×{viewport.h}
              </span>
            )}
          </>
        }
        rightSlot={
          <>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                void importFromCode();
              }}
              disabled={importing}
              title="Read this workspace's SwiftUI screens onto the canvas (fast import — no terminal agent involved)"
              className="text-panel-header-foreground/80 hover:bg-panel-header-foreground/10 hover:text-panel-header-foreground"
            >
              {importing ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <FileDown className="size-3.5" />
              )}
              Import
            </Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={clearMock}
              disabled={screenCount === 0}
              className="text-panel-header-foreground/80 hover:bg-panel-header-foreground/10 hover:text-panel-header-foreground"
            >
              <Trash2 className="size-3.5" />
              Clear
            </Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                void startPreview();
              }}
              disabled={previewBusy}
              title={
                previewState === 'connected'
                  ? 'Preview live — canvas edits mirror to the simulator in real time'
                  : previewState === 'disconnected'
                    ? 'Preview app lost its connection — click to relaunch'
                    : 'Launch the live preview app on the booted simulator (first run builds it once, ~30–60s)'
              }
              className="text-panel-header-foreground/80 hover:bg-panel-header-foreground/10 hover:text-panel-header-foreground"
            >
              <span
                aria-hidden
                className={cn(
                  'size-2 rounded-full',
                  previewState === 'connected' && 'bg-secondary',
                  previewState === 'disconnected' && 'bg-destructive',
                  previewState === 'error' && 'bg-destructive',
                  previewState === 'busy' && 'animate-pulse bg-warning',
                  previewState === 'stopped' && 'bg-panel-header-foreground/30',
                )}
              />
              {previewBusy ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <Play className="size-3.5" />
              )}
              Preview
            </Button>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => {
                void exportAndRun();
              }}
              disabled={exporting || screenCount === 0}
              title="Generate SwiftUI into TangoGenerated/, build, and launch on the simulator"
            >
              {exporting ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <Rocket className="size-3.5" />
              )}
              Export &amp; Run
            </Button>
            <Button
              size="sm"
              onClick={sendToClaude}
              disabled={sendBusy || screenCount === 0}
            >
              {sendBusy ? (
                <RefreshCw className="size-3.5 animate-spin" />
              ) : (
                <Send className="size-3.5" />
              )}
              {terminalAgentMeta.sendLabel}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setSidebarOpen((o) => !o)}
              title={sidebarOpen ? 'Hide design sidebar' : 'Show design sidebar'}
              aria-pressed={sidebarOpen}
              className={cn(
                'text-panel-header-foreground/80 hover:bg-panel-header-foreground/10 hover:text-panel-header-foreground',
                sidebarOpen && 'text-panel-header-foreground',
              )}
            >
              <PanelRight className="size-3.5" />
            </Button>
          </>
        }
      />

      <div className="flex min-h-0 flex-1">
        <div ref={viewportRef} className="relative min-h-0 min-w-0 flex-1">
          {load.status === 'ready' && (
            <UIMockCanvas
              key={generation}
              initialSpec={load.initialSpec}
              onPersist={persist}
              onActiveScreen={handleActiveScreen}
              sidebarContainer={sidebarOpen ? sidebarEl : null}
            />
          )}
        </div>
        {sidebarOpen && (
          <div
            ref={sidebarRef}
            className="w-64 shrink-0 overflow-hidden border-l border-border bg-card"
          />
        )}
      </div>

      {status && (
        <div className="shrink-0 border-t border-border bg-background px-4 py-2 font-mono text-[11px] text-muted-foreground">
          {status}
        </div>
      )}
    </div>
  );
}

// Markdown handoff to the active terminal agent. The JSON is the source of
// truth; the prose tells the agent what to do.
function buildHandoffPrompt(spec: UISpec): string {
  const screens = spec.screens
    .map(
      (s) =>
        `- ${s.title} (${s.frame.w}×${s.frame.h}, ${s.nodes.length} node${s.nodes.length === 1 ? '' : 's'})`,
    )
    .join('\n');
  return [
    'Use this UI mock as the source of truth for the next prod-UI pass.',
    '',
    `Screens:`,
    screens,
    '',
    'Mock spec (JSON — read carefully, the user has likely tweaked positions, sizes, and text since you last set it):',
    '```json',
    JSON.stringify(spec, null, 2),
    '```',
    '',
    'Translate the changes to the production UI. The mock uses absolute pixel coordinates inside fixed frames — do **not** ship absolute positions. Reach for responsive Tailwind (flex/grid, container queries when sensible) and shadcn primitives that match the node `type`s. Inspect the existing source for the screen first; preserve behavior, naming, and routing. Tell me which files you plan to touch before editing.',
  ].join('\n');
}
