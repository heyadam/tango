'use client';

import { useEffect, useRef, useState } from 'react';
import { Terminal as Xterm } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { Code2 } from 'lucide-react';
import { terminalBus } from '@/lib/terminalBus';
import { openWS } from '@/lib/wsClient';

export default function Terminal() {
  const containerRef = useRef<HTMLDivElement | null>(null);
  // Bumping this counter forces the effect below to re-run, which tears down
  // the existing xterm + WS and creates a fresh pair. Driven by the
  // server-sent `workspace_changed` JSON frame on the same WS — that's the
  // canonical signal so it works for every connected tab, not just the one
  // that triggered the switch. (Don't add a workspaceBus subscription here —
  // it would double-bump and re-kill the freshly-spawned `claude`.)
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Xterm({
      convertEol: false,
      cursorBlink: true,
      fontFamily:
        'ui-monospace, SFMono-Regular, Menlo, Monaco, "Cascadia Code", "Source Code Pro", monospace',
      fontSize: 13,
      theme: {
        background: '#0a0a0a',
        foreground: '#e5e5e5',
        cursor: '#e5e5e5',
        selectionBackground: '#264f78',
      },
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    try {
      fitAddon.fit();
    } catch {
      // container has zero size on first paint; ResizeObserver will fix it
    }

    const ws = openWS('/ws/terminal');
    ws.binaryType = 'arraybuffer';

    const decoder = new TextDecoder('utf-8');
    const encoder = new TextEncoder();

    const sendBinary = (text: string) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      ws.send(encoder.encode(text));
    };

    const sendResize = () => {
      if (ws.readyState !== WebSocket.OPEN) return;
      ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
    };

    ws.addEventListener('open', () => {
      try {
        fitAddon.fit();
      } catch {
        /* noop */
      }
      sendResize();
      term.focus();
    });

    ws.addEventListener('message', (ev) => {
      const data = ev.data;
      if (data instanceof ArrayBuffer) {
        const bytes = new Uint8Array(data);
        term.write(bytes);
        terminalBus._emitOutput(decoder.decode(bytes));
        return;
      }
      if (typeof data === 'string') {
        // Server-sent JSON control frame on the same WS — currently only
        // workspace_changed. Detected by trying to parse; everything else
        // is treated as terminal text.
        let parsed: unknown;
        try {
          parsed = JSON.parse(data);
        } catch {
          term.write(data);
          terminalBus._emitOutput(data);
          return;
        }
        if (
          parsed != null &&
          typeof parsed === 'object' &&
          'type' in (parsed as Record<string, unknown>) &&
          (parsed as { type: unknown }).type === 'workspace_changed'
        ) {
          // Trigger a generation bump so this effect tears down and
          // re-runs, opening a fresh PTY in the new cwd.
          setGeneration((g) => g + 1);
          return;
        }
        term.write(data);
        terminalBus._emitOutput(data);
      }
    });

    ws.addEventListener('close', () => {
      term.write('\r\n\x1b[31m[connection closed]\x1b[0m\r\n');
    });

    ws.addEventListener('error', () => {
      term.write('\r\n\x1b[31m[connection error]\x1b[0m\r\n');
    });

    const dataDisposable = term.onData((data) => sendBinary(data));

    const unsubscribeBus = terminalBus._onSend((text) => sendBinary(text));

    let resizeTimer: ReturnType<typeof setTimeout> | null = null;
    const ro = new ResizeObserver(() => {
      if (resizeTimer) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        try {
          fitAddon.fit();
        } catch {
          /* noop */
        }
        sendResize();
      }, 50);
    });
    ro.observe(container);

    return () => {
      unsubscribeBus();
      dataDisposable.dispose();
      ro.disconnect();
      if (resizeTimer) clearTimeout(resizeTimer);
      try {
        ws.close();
      } catch {
        /* noop */
      }
      term.dispose();
    };
  }, [generation]);

  return (
    <div className="flex h-full w-full flex-col">
      <div className="flex h-12 shrink-0 items-center gap-1.5 border-b border-border bg-panel-header px-3 text-xs font-medium text-panel-header-foreground">
        <Code2 className="size-3.5 text-panel-header-foreground/70" />
        <span>Claude Code</span>
      </div>
      <div ref={containerRef} className="min-h-0 flex-1 bg-[#0a0a0a] p-2" />
    </div>
  );
}
