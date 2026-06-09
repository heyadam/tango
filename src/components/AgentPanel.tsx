'use client';

// The built-in agent panel: a chat UI over /ws/agent (Claude Agent SDK
// session on the server) shown in the middle pane when the 'tango' terminal
// agent is selected. Replaces xterm for the built-in agent — assistant text
// streams as chat bubbles, tool calls render as compact chips.
//
// Bridges terminalBus like the Terminal component does: UIPanel's Send /
// Import actions write text + '\r' through the bus; createSubmitBuffer turns
// that PTY-shaped stream back into whole messages.

import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowUp, Hammer, Sparkles, Square } from 'lucide-react';
import PanelHeader from '@/components/PanelHeader';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { terminalBus } from '@/lib/terminalBus';
import {
  createSubmitBuffer,
  type AgentServerMsg,
} from '@/lib/agentProtocol';
import {
  TERMINAL_AGENTS,
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { openWS } from '@/lib/wsClient';

type TranscriptItem =
  | { kind: 'user'; text: string }
  | { kind: 'assistant'; text: string; streaming: boolean }
  | { kind: 'tool'; name: string; detail: string }
  | { kind: 'error'; text: string };

type Props = {
  terminalAgent: TerminalAgentId;
  onTerminalAgentChanged: (agent: TerminalAgentId) => void;
};

export default function AgentPanel({
  terminalAgent,
  onTerminalAgentChanged,
}: Props) {
  // Bumped on workspace_changed so the effect reopens the socket against the
  // new workspace's session (same pattern as Terminal.tsx).
  const [generation, setGeneration] = useState(0);
  const [items, setItems] = useState<TranscriptItem[]>([]);
  const [busy, setBusy] = useState(false);
  const [statusText, setStatusText] = useState<string | null>(null);
  const [model, setModel] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const wsRef = useRef<WebSocket | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  const appendDelta = useCallback((text: string) => {
    setItems((prev) => {
      const last = prev[prev.length - 1];
      if (last && last.kind === 'assistant' && last.streaming) {
        return [
          ...prev.slice(0, -1),
          { ...last, text: last.text + text },
        ];
      }
      return [...prev, { kind: 'assistant', text, streaming: true }];
    });
  }, []);

  const closeStreamingBubble = useCallback(() => {
    setItems((prev) => {
      const last = prev[prev.length - 1];
      if (last && last.kind === 'assistant' && last.streaming) {
        return [...prev.slice(0, -1), { ...last, streaming: false }];
      }
      return prev;
    });
  }, []);

  const submit = useCallback((text: string) => {
    const trimmed = text.trim();
    if (trimmed.length === 0) return;
    const ws = wsRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      setItems((prev) => [
        ...prev,
        { kind: 'error', text: 'not connected — message not sent' },
      ]);
      return;
    }
    setItems((prev) => [...prev, { kind: 'user', text: trimmed }]);
    setBusy(true);
    setStatusText(null);
    ws.send(JSON.stringify({ type: 'user_message', text: trimmed }));
  }, []);

  const interrupt = useCallback(() => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'interrupt' }));
      setStatusText('Stopping…');
    }
  }, []);

  useEffect(() => {
    const ws = openWS('/ws/agent');
    wsRef.current = ws;
    setItems([]);
    setBusy(false);
    setModel(null);
    setStatusText('Connecting…');

    ws.addEventListener('message', (ev) => {
      if (typeof ev.data !== 'string') return;
      let msg: AgentServerMsg;
      try {
        msg = JSON.parse(ev.data) as AgentServerMsg;
      } catch {
        return;
      }
      switch (msg.type) {
        case 'ready':
          setModel(msg.model);
          setStatusText(null);
          return;
        case 'status':
          setStatusText(msg.text);
          return;
        case 'text_delta':
          appendDelta(msg.text);
          return;
        case 'text_done':
          closeStreamingBubble();
          return;
        case 'tool_use':
          setItems((prev) => [
            ...prev,
            { kind: 'tool', name: msg.name, detail: msg.detail },
          ]);
          return;
        case 'turn_done': {
          closeStreamingBubble();
          setBusy(false);
          if (!msg.ok && msg.error) {
            setItems((prev) => [
              ...prev,
              { kind: 'error', text: msg.error as string },
            ]);
          }
          const secs =
            msg.durationMs != null
              ? `${(msg.durationMs / 1000).toFixed(1)}s`
              : null;
          const cost =
            msg.costUsd != null ? `$${msg.costUsd.toFixed(2)}` : null;
          setStatusText([secs, cost].filter(Boolean).join(' · ') || null);
          return;
        }
        case 'error':
          closeStreamingBubble();
          setBusy(false);
          setItems((prev) => [...prev, { kind: 'error', text: msg.message }]);
          return;
        case 'workspace_changed':
          setGeneration((g) => g + 1);
          return;
        case 'terminal_agent_changed': {
          const next = msg.agent;
          if (isTerminalAgentId(next) && next !== terminalAgent) {
            onTerminalAgentChanged(next);
          }
          return;
        }
      }
    });

    ws.addEventListener('open', () => {
      setStatusText(null);
      textareaRef.current?.focus();
    });
    ws.addEventListener('close', (ev) => {
      setBusy(false);
      setStatusText(
        ev.code === 4001 ? 'No workspace selected.' : 'Disconnected.',
      );
    });
    ws.addEventListener('error', () => {
      setStatusText('Connection error.');
    });

    return () => {
      wsRef.current = null;
      try {
        ws.close();
      } catch {
        // already closed
      }
    };
  }, [
    generation,
    appendDelta,
    closeStreamingBubble,
    onTerminalAgentChanged,
    terminalAgent,
  ]);

  // terminalBus seam: UIPanel's Send/Import write text then '\r' as separate
  // chunks (PTY semantics); the buffer reassembles them into one message.
  useEffect(() => {
    const buffer = createSubmitBuffer(submit);
    return terminalBus._onSend((chunk) => buffer.push(chunk));
  }, [submit]);

  // Pin the transcript to the bottom as content streams in.
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [items]);

  const onKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        submit(draft);
        setDraft('');
      }
    },
    [draft, submit],
  );

  return (
    <div className="flex h-full w-full flex-col bg-background">
      <PanelHeader
        icon={Sparkles}
        title={TERMINAL_AGENTS[terminalAgent].label}
        rightSlot={
          model ? (
            <span className="font-mono text-[10px] text-panel-header-foreground/60">
              {model}
            </span>
          ) : undefined
        }
      />

      <div
        ref={scrollRef}
        className="min-h-0 flex-1 overflow-y-auto px-3 py-3"
      >
        {items.length === 0 && (
          <div className="flex h-full items-center justify-center px-6 text-center text-xs text-muted-foreground/60">
            Ask for design changes, imports, builds — the agent has the canvas
            and the simulator at hand.
          </div>
        )}
        <div className="flex flex-col gap-2">
          {items.map((item, i) => (
            <TranscriptRow key={i} item={item} />
          ))}
          {busy && (
            <div className="flex items-center gap-1.5 px-1 text-xs text-muted-foreground">
              <span className="size-1.5 animate-pulse rounded-full bg-primary" />
              Working…
            </div>
          )}
        </div>
      </div>

      <div className="shrink-0 border-t border-border p-2">
        <div className="flex items-end gap-2 rounded-md border border-border bg-card px-2 py-1.5 focus-within:ring-1 focus-within:ring-ring/50">
          <textarea
            ref={textareaRef}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            rows={2}
            placeholder="Message the agent… (Enter to send)"
            className="max-h-40 min-h-0 flex-1 resize-none bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground/60"
          />
          {busy ? (
            <Button
              size="icon-sm"
              variant="outline"
              onClick={interrupt}
              aria-label="Stop the agent"
              title="Stop"
            >
              <Square className="size-3.5" />
            </Button>
          ) : (
            <Button
              size="icon-sm"
              onClick={() => {
                submit(draft);
                setDraft('');
              }}
              disabled={draft.trim().length === 0}
              aria-label="Send message"
              title="Send"
            >
              <ArrowUp className="size-3.5" />
            </Button>
          )}
        </div>
        {statusText && (
          <div className="px-1 pt-1 font-mono text-[10px] text-muted-foreground">
            {statusText}
          </div>
        )}
      </div>
    </div>
  );
}

function TranscriptRow({ item }: { item: TranscriptItem }) {
  if (item.kind === 'user') {
    return (
      <div className="ml-8 self-end rounded-lg bg-primary/10 px-3 py-1.5 text-sm whitespace-pre-wrap text-foreground">
        {item.text}
      </div>
    );
  }
  if (item.kind === 'assistant') {
    return (
      <div className="mr-4 px-1 text-sm leading-relaxed whitespace-pre-wrap text-foreground">
        {item.text}
        {item.streaming && (
          <span className="ml-0.5 inline-block h-3.5 w-1 animate-pulse bg-primary align-middle" />
        )}
      </div>
    );
  }
  if (item.kind === 'tool') {
    return (
      <div className="flex items-center gap-1.5 px-1 text-xs text-muted-foreground">
        <Hammer className="size-3 shrink-0" />
        <span className="font-medium">{item.name}</span>
        {item.detail && (
          <span className="truncate font-mono text-[11px] text-muted-foreground/70">
            {item.detail}
          </span>
        )}
      </div>
    );
  }
  return (
    <div
      className={cn(
        'rounded-md border border-destructive/30 bg-destructive/5 px-2 py-1.5 text-xs text-destructive',
      )}
    >
      {item.text}
    </div>
  );
}
