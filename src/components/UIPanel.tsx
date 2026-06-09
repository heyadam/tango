'use client';

// The left panel: an SSR-safe shell around the design canvas. Owns the
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
import { Frame, RefreshCw, Send, Trash2 } from 'lucide-react';
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

// Subtracted from the wrapper rect when reporting "viewport" to Claude so
// the size is the largest frame that fits *without scrolling*. Mirrors
// UIMockCanvas's inner `gap-20 p-10` (40px outer padding each side → 80px
// per axis) plus each screen's title row above the frame (text-xs ≈ 16px
// + gap-2 = 8px → ~24px on top, none on bottom). If those classes change
// in UIMockCanvas, update these in lockstep.
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
      if (!last) return;
      try {
        ws.send(JSON.stringify({ type: 'viewport', w: last.w, h: last.h }));
      } catch {
        // socket dying — cleanup runs on close
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
              onClick={clearMock}
              disabled={screenCount === 0}
              className="text-panel-header-foreground/80 hover:bg-panel-header-foreground/10 hover:text-panel-header-foreground"
            >
              <Trash2 className="size-3.5" />
              Clear
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
          </>
        }
      />

      <div ref={viewportRef} className="relative min-h-0 flex-1">
        {load.status === 'ready' && (
          <UIMockCanvas
            key={generation}
            initialSpec={load.initialSpec}
            onPersist={persist}
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
