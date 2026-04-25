'use client';

import { useEffect, useRef } from 'react';
import { Terminal as Xterm } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { terminalBus } from '@/lib/terminalBus';

export default function Terminal() {
  const containerRef = useRef<HTMLDivElement | null>(null);

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

    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${location.host}/ws/terminal`);
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
      } else if (typeof data === 'string') {
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
  }, []);

  return <div ref={containerRef} className="h-full w-full bg-[#0a0a0a] p-2" />;
}
