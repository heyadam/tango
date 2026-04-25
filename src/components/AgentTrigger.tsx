'use client';

import { useState } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';

export default function AgentTrigger() {
  const [input, setInput] = useState('');
  const [open, setOpen] = useState(false);
  const { messages, sendMessage, status, error } = useChat({
    transport: new DefaultChatTransport({ api: '/api/agent' }),
  });

  const busy = status === 'submitted' || status === 'streaming';

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const text = input.trim();
    if (!text || busy) return;
    void sendMessage({ text });
    setInput('');
    setOpen(true);
  };

  return (
    <div className="flex flex-col items-end gap-2">
      <form onSubmit={submit} className="flex items-center gap-2">
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Tell the agent what to do…"
          className="w-72 rounded-md border border-neutral-700 bg-neutral-950 px-3 py-1.5 text-xs text-neutral-100 placeholder:text-neutral-500 focus:border-sky-500 focus:outline-none"
          disabled={busy}
        />
        <button
          type="submit"
          disabled={busy || input.trim().length === 0}
          className="rounded-md border border-sky-500/40 bg-sky-500/15 px-3 py-1.5 text-xs font-medium text-sky-200 transition-colors hover:border-sky-400 hover:bg-sky-500/25 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {busy ? 'Running…' : 'Run agent'}
        </button>
        {messages.length > 0 && (
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            className="rounded-md border border-neutral-700 bg-neutral-800 px-2 py-1.5 text-[11px] text-neutral-300 hover:border-neutral-500"
          >
            {open ? 'Hide log' : 'Show log'}
          </button>
        )}
      </form>
      {open && messages.length > 0 && (
        <div className="max-h-72 w-[28rem] overflow-y-auto rounded-md border border-neutral-800 bg-neutral-950 p-2 text-[11px] leading-relaxed text-neutral-200">
          {messages.map((m) => (
            <div key={m.id} className="mb-2 last:mb-0">
              <div className="mb-0.5 font-mono text-[10px] uppercase tracking-wide text-neutral-500">
                {m.role}
              </div>
              {m.parts?.map((part, i) => {
                if (part.type === 'text') {
                  return (
                    <div key={i} className="whitespace-pre-wrap text-neutral-200">
                      {part.text}
                    </div>
                  );
                }
                if (typeof part.type === 'string' && part.type.startsWith('tool-')) {
                  const name = part.type.slice('tool-'.length);
                  const partAny = part as unknown as {
                    state?: string;
                    input?: unknown;
                    output?: unknown;
                  };
                  return (
                    <div
                      key={i}
                      className="my-1 rounded border border-neutral-800 bg-neutral-900 px-2 py-1 font-mono text-[10px] text-neutral-300"
                    >
                      <div className="text-sky-300">
                        {name}
                        {partAny.state ? ` · ${partAny.state}` : ''}
                      </div>
                      {partAny.input !== undefined && (
                        <pre className="mt-0.5 whitespace-pre-wrap text-neutral-400">
                          {JSON.stringify(partAny.input, null, 2)}
                        </pre>
                      )}
                      {partAny.output !== undefined && (
                        <pre className="mt-0.5 whitespace-pre-wrap text-neutral-500">
                          → {JSON.stringify(partAny.output, null, 2)}
                        </pre>
                      )}
                    </div>
                  );
                }
                return null;
              })}
            </div>
          ))}
          {error && (
            <div className="mt-1 font-mono text-[10px] text-red-400">
              {error.message}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
