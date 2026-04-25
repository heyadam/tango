'use client';

import { useEffect, useState } from 'react';
import { terminalBus } from '@/lib/terminalBus';

const MAX_LINES = 12;

// Strip ANSI/C1: OSC, CSI, two-byte ESC sequences, and stray BEL/ESC.
// Also resolves backspace (\b) so prompt-redraw artifacts read normally.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\][\s\S]*?(?:\x07|\x1b\\)|\x1b\[[0-9;?<>=!]*[a-zA-Z@`~]|\x1b[=>78@-Z\\-_]|[\x07\x1b]/g;
const stripAnsi = (s: string) => {
  const noEsc = s.replace(ANSI_RE, '');
  // Apply backspaces left-to-right.
  let out = '';
  for (const ch of noEsc) {
    if (ch === '\b') out = out.slice(0, -1);
    else out += ch;
  }
  return out;
};

export default function LeftPanel() {
  const [tail, setTail] = useState<string[]>([]);

  useEffect(() => {
    let buffer = '';
    return terminalBus.onTerminalOutput((data) => {
      buffer += data;
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop() ?? '';
      if (lines.length === 0) return;
      const clean = lines.map((l) => stripAnsi(l).replace(/\r/g, '').trimEnd());
      setTail((prev) => [...prev, ...clean].slice(-MAX_LINES));
    });
  }, []);

  return (
    <div className="flex h-full flex-col gap-6 overflow-auto p-8">
      <header className="flex flex-col gap-2">
        <h1 className="text-2xl font-semibold tracking-tight">tango</h1>
        <p className="text-sm text-neutral-500">
          Left panel placeholder. The right sidebar is a real shell connected
          via WebSocket. The two are wired through{' '}
          <code className="rounded bg-neutral-800 px-1.5 py-0.5 text-xs text-neutral-200">
            terminalBus
          </code>
          .
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-sm font-medium text-neutral-400">Send to terminal</h2>
        <div className="flex flex-wrap gap-2">
          <SendButton command="pwd" />
          <SendButton command="ls -la" />
          <SendButton command="echo $SHELL" />
          <SendButton command={'echo "from left panel"'} />
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-sm font-medium text-neutral-400">
          Last {MAX_LINES} lines from terminal
        </h2>
        <pre className="min-h-32 flex-1 rounded-md border border-neutral-800 bg-neutral-950 p-3 text-xs leading-relaxed text-neutral-300">
          {tail.length === 0 ? (
            <span className="text-neutral-600">(no output yet)</span>
          ) : (
            tail.join('\n')
          )}
        </pre>
      </section>
    </div>
  );
}

function SendButton({ command }: { command: string }) {
  return (
    <button
      type="button"
      onClick={() => terminalBus.sendToTerminal(`${command}\r`)}
      className="rounded-md border border-neutral-700 bg-neutral-900 px-3 py-1.5 font-mono text-xs text-neutral-200 transition-colors hover:border-neutral-500 hover:bg-neutral-800"
    >
      {command}
    </button>
  );
}
