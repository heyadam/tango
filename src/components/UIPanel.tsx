'use client';

// SSR-safe shell for "UI" mode. Owns the /ws/ui-mock socket and dynamic-imports
// UIMockCanvas (react-moveable touches `window` at module load). Same pattern
// as SketchPanel + DesignerCanvas.
//
// "Send to Claude" packages the current spec into a markdown handoff prompt
// and submits it to the terminal-Claude session via terminalBus. The spec
// JSON is the source of truth for what the user wants — Claude reads it and
// translates the absolute-positioned mock into responsive Tailwind in the
// production codebase. The user's drag/resize tweaks are visible to Claude
// as updated coords on its next `get_ui_mock` read.

import { useCallback, useEffect, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import { RefreshCw, Send, Trash2 } from 'lucide-react';
import { Button } from './ui/button';
import { uiMockBus } from '@/lib/uiMockBus';
import { uiMockStore } from '@/lib/uiMockStore';
import { EMPTY_SPEC, type UISpec } from '@/lib/uiMockProtocol';
import { workspaceBus } from '@/lib/workspaceBus';
import { openWS } from '@/lib/wsClient';
import { terminalBus } from '@/lib/terminalBus';

const UIMockCanvas = dynamic(() => import('./UIMockCanvas'), {
  ssr: false,
  loading: () => <div className="h-full w-full bg-neutral-950" />,
});

type LoadState =
  | { status: 'loading' }
  | { status: 'ready'; initialSpec: UISpec };

export default function UIPanel() {
  const [load, setLoad] = useState<LoadState>({ status: 'loading' });
  // Bumping this remounts UIMockCanvas (and re-runs the WS effect) so a
  // workspace switch starts from a clean slate.
  const [generation, setGeneration] = useState(0);
  const [sendBusy, setSendBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);

  // Latest spec — kept in a ref so "Send to Claude" / "Clear" don't have to
  // re-render to read it. Updated on every server `set` and every local
  // snapshot.
  const specRef = useRef<UISpec>(EMPTY_SPEC);

  // On workspace switch: drop local cache and remount.
  useEffect(() => {
    return workspaceBus.subscribe(() => {
      uiMockStore.clear();
      specRef.current = EMPTY_SPEC;
      setLoad({ status: 'loading' });
      setGeneration((g) => g + 1);
    });
  }, []);

  // Hydrate the initial spec from localStorage so a refresh keeps the user's
  // last view. The server's `set` on WS connect will replace this if the
  // server's cache differs.
  useEffect(() => {
    const initial = uiMockStore.load();
    specRef.current = initial;
    setLoad({ status: 'ready', initialSpec: initial });
  }, [generation]);

  const persist = useCallback((spec: UISpec) => {
    specRef.current = spec;
    uiMockStore.save(spec);
  }, []);

  // Open the WS bridge: outbound snapshots flow through uiMockBus from the
  // canvas; inbound apply messages go to the canvas via the same bus.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const ws = openWS('/ws/ui-mock');

    const offSnapshot = uiMockBus._onSnapshot((spec) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: 'snapshot', spec }));
      } catch {
        // socket dying — cleanup runs on close
      }
    });

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
      if (msg.type === 'set' || msg.type === 'append_screen') {
        // Persist server-driven full replacements too so a refresh keeps them.
        if (msg.type === 'set') {
          const setMsg = parsed as { type: 'set'; spec: UISpec };
          specRef.current = setMsg.spec;
          uiMockStore.save(setMsg.spec);
        }
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        uiMockBus._emitApply(parsed as any);
      }
    });

    return () => {
      offSnapshot();
      try {
        ws.close();
      } catch {
        // already closed
      }
    };
  }, [generation]);

  const sendToClaude = useCallback(async () => {
    if (sendBusy) return;
    const spec = specRef.current;
    if (!spec.screens || spec.screens.length === 0) {
      setStatus('Mock is empty — ask Claude to draft one first.');
      return;
    }
    setSendBusy(true);
    setStatus(null);
    try {
      const handoff = buildHandoffPrompt(spec);
      terminalBus.submitToTerminal(handoff);
      setStatus(
        `Sent ${spec.screens.length} screen${spec.screens.length === 1 ? '' : 's'} to Claude.`,
      );
    } catch (err) {
      setStatus(
        `Send failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      setSendBusy(false);
    }
  }, [sendBusy]);

  const clearMock = useCallback(() => {
    // Local clear: emit an empty snapshot so the server cache matches and
    // any open browsers see the same state on refresh. We don't call MCP from
    // here — clear_ui_mock is for Claude.
    const empty: UISpec = { screens: [] };
    specRef.current = empty;
    uiMockStore.save(empty);
    uiMockBus._emitApply({ type: 'set', spec: empty });
    uiMockBus._emitSnapshot(empty);
    setStatus('Cleared.');
  }, []);

  const screenCount = load.status === 'ready' ? load.initialSpec.screens.length : 0;

  return (
    <div className="flex h-full min-h-0 flex-col bg-neutral-950 text-neutral-100">
      <header className="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-neutral-900 bg-neutral-950 px-4">
        <div className="flex min-w-0 items-center gap-3">
          <h1 className="text-sm font-semibold text-neutral-100">UI mock</h1>
          {load.status === 'ready' && screenCount > 0 && (
            <span className="text-xs text-neutral-500">
              {screenCount} screen{screenCount === 1 ? '' : 's'}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={clearMock}
            disabled={screenCount === 0}
            className="h-8 text-neutral-400 hover:text-neutral-100"
          >
            <Trash2 className="size-3.5" />
            Clear
          </Button>
          <Button
            size="sm"
            onClick={sendToClaude}
            disabled={sendBusy || screenCount === 0}
            className="h-8 bg-emerald-300 text-neutral-950 hover:bg-emerald-200 disabled:bg-neutral-800 disabled:text-neutral-500"
          >
            {sendBusy ? (
              <RefreshCw className="size-3.5 animate-spin" />
            ) : (
              <Send className="size-3.5" />
            )}
            Send to Claude
          </Button>
        </div>
      </header>

      <div className="relative min-h-0 flex-1">
        {load.status === 'ready' && (
          <UIMockCanvas
            key={generation}
            initialSpec={load.initialSpec}
            onPersist={persist}
          />
        )}
      </div>

      {status && (
        <div className="shrink-0 border-t border-neutral-900 bg-neutral-950 px-4 py-2 font-mono text-[11px] text-neutral-400">
          {status}
        </div>
      )}
    </div>
  );
}

// Markdown handoff to terminal-Claude. Mirrors moodboard's pattern: the JSON
// is the source of truth; the prose tells Claude what to do with it.
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
