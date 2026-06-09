'use client';

// The built-in agent panel: a chat UI over /ws/agent (Claude Agent SDK
// session on the server) shown in the middle pane when the 'tango' terminal
// agent is selected. Replaces xterm for the built-in agent — assistant text
// streams as markdown bubbles, consecutive tool calls fold into grouped rows.
//
// Bridges terminalBus like the Terminal component does: UIPanel's Send /
// Import actions write text + '\r' through the bus; createSubmitBuffer turns
// that PTY-shaped stream back into whole messages.

import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  ArrowDown,
  ArrowUp,
  Bot,
  CircleAlert,
  Eye,
  FilePen,
  FileText,
  Globe,
  LayoutDashboard,
  ListChecks,
  Loader2,
  Play,
  Search,
  Smartphone,
  Sparkles,
  Square,
  SquareTerminal,
  StickyNote,
  Wrench,
  type LucideIcon,
} from 'lucide-react';
import PanelHeader from '@/components/PanelHeader';
import AgentMarkdown from '@/components/AgentMarkdown';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { terminalBus } from '@/lib/terminalBus';
import {
  createSubmitBuffer,
  type AgentServerMsg,
} from '@/lib/agentProtocol';
import {
  groupTranscript,
  type ToolItem,
  type ToolsGroup,
  type TranscriptEntry,
  type TranscriptItem,
} from '@/lib/agentTranscript';
import {
  TERMINAL_AGENTS,
  isTerminalAgentId,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { openWS } from '@/lib/wsClient';

type ConnState = 'connecting' | 'open' | 'closed' | 'no-workspace';

type Props = {
  terminalAgent: TerminalAgentId;
  onTerminalAgentChanged: (agent: TerminalAgentId) => void;
};

const EXAMPLE_PROMPTS = [
  'Add a sign-in screen',
  "Import this project's screens",
  'Run it on the simulator',
];

// Considered pinned to the bottom while within this many px of it.
const PIN_THRESHOLD_PX = 48;

// Per-tool icon. Names arrive as display names (the bridge applies
// displayToolName before sending), so MCP tools match on their bare name.
function toolIcon(name: string): LucideIcon {
  switch (name) {
    case 'Bash':
      return SquareTerminal;
    case 'Read':
      return FileText;
    case 'Write':
    case 'Edit':
    case 'NotebookEdit':
      return FilePen;
    case 'Glob':
    case 'Grep':
      return Search;
    case 'WebFetch':
    case 'WebSearch':
      return Globe;
    case 'Task':
      return Bot;
    case 'Skill':
      return Sparkles;
    case 'TodoWrite':
      return ListChecks;
    case 'export_run':
      return Play;
    case 'preview_start':
      return Eye;
    case 'remember_note':
      return StickyNote;
  }
  if (/^(get|set|add|update|remove|reorder|clear)_ui_/.test(name)) {
    return LayoutDashboard;
  }
  if (name.startsWith('ios_')) return Smartphone;
  return Wrench;
}

export default function AgentPanel({
  terminalAgent,
  onTerminalAgentChanged,
}: Props) {
  // Bumped on workspace_changed (and Reconnect) so the effect reopens the
  // socket against the new workspace's session (same pattern as Terminal.tsx).
  const [generation, setGeneration] = useState(0);
  const [items, setItems] = useState<TranscriptItem[]>([]);
  const [busy, setBusy] = useState(false);
  const [statusText, setStatusText] = useState<string | null>(null);
  const [model, setModel] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [connState, setConnState] = useState<ConnState>('connecting');
  const [jumpVisible, setJumpVisible] = useState(false);
  const [inputFocused, setInputFocused] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  // Whether the user is at (or near) the bottom of the transcript. A ref, not
  // state — it changes on every scroll tick and only effects read it.
  const pinnedRef = useRef(true);

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

  // Finalizes any streaming assistant bubble, wherever it sits. Scanning the
  // whole list (not just the last item) matters: queueing a user message
  // mid-stream pushes the streaming bubble away from the end, and a
  // last-item-only repair would leave it streaming:true forever. Untouched
  // items keep identity (load-bearing for the memo'd rows).
  const closeStreamingBubble = useCallback(() => {
    setItems((prev) =>
      prev.some((it) => it.kind === 'assistant' && it.streaming)
        ? prev.map((it) =>
            it.kind === 'assistant' && it.streaming
              ? { ...it, streaming: false }
              : it,
          )
        : prev,
    );
  }, []);

  // Returns true when the message was actually sent (so callers can decide
  // whether to clear the draft).
  const submit = useCallback(
    (text: string): boolean => {
      const trimmed = text.trim();
      if (trimmed.length === 0) return false;
      const ws = wsRef.current;
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        setItems((prev) => [
          ...prev,
          { kind: 'error', text: 'not connected — message not sent' },
        ]);
        return false;
      }
      // Queueing mid-stream: finalize the in-flight assistant bubble first so
      // the next text_delta opens a fresh bubble below this user message
      // instead of splitting the old paragraph around it.
      closeStreamingBubble();
      setItems((prev) => [...prev, { kind: 'user', text: trimmed }]);
      // Snap to the bottom on own send (conventional chat behavior) — the
      // [items] auto-scroll effect picks this up on the same commit.
      pinnedRef.current = true;
      setJumpVisible(false);
      setBusy(true);
      setStatusText(null);
      ws.send(JSON.stringify({ type: 'user_message', text: trimmed }));
      return true;
    },
    [closeStreamingBubble],
  );

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
    setConnState('connecting');
    setStatusText('Connecting…');
    // Re-arm auto-follow alongside the transcript reset: an emptied list
    // fires no scroll event (especially at scrollTop 0), so onScroll would
    // never recompute pinned and a stale jump pill would float over the
    // empty state.
    pinnedRef.current = true;
    setJumpVisible(false);

    ws.addEventListener('message', (ev) => {
      if (wsRef.current !== ws) return;
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
          setStatusText(null);
          if (!msg.ok && msg.error) {
            setItems((prev) => [
              ...prev,
              { kind: 'error', text: msg.error as string },
            ]);
          }
          if (msg.ok) {
            const secs =
              msg.durationMs != null
                ? `${(msg.durationMs / 1000).toFixed(1)}s`
                : null;
            const cost =
              msg.costUsd != null ? `$${msg.costUsd.toFixed(2)}` : null;
            const text = [secs, cost].filter(Boolean).join(' · ');
            if (text) {
              setItems((prev) => [...prev, { kind: 'meta', text }]);
            }
          }
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
      if (wsRef.current !== ws) return;
      setConnState('open');
      setStatusText(null);
      textareaRef.current?.focus();
    });
    ws.addEventListener('close', (ev) => {
      if (wsRef.current !== ws) return;
      setBusy(false);
      setStatusText(null);
      setConnState(ev.code === 4001 ? 'no-workspace' : 'closed');
    });
    ws.addEventListener('error', () => {
      if (wsRef.current !== ws) return;
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

  // Smart auto-scroll: follow the stream only while the user is pinned to the
  // bottom; otherwise surface the jump-to-latest pill. Instant scrolling —
  // smooth behavior janks under rapid text deltas.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    if (pinnedRef.current) {
      el.scrollTop = el.scrollHeight;
    } else if (items.length > 0) {
      setJumpVisible(true);
    }
  }, [items, busy]);

  const onScroll = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    const pinned =
      el.scrollHeight - el.scrollTop - el.clientHeight < PIN_THRESHOLD_PX;
    pinnedRef.current = pinned;
    if (pinned) setJumpVisible(false);
  }, []);

  const jumpToLatest = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
    pinnedRef.current = true;
    setJumpVisible(false);
  }, []);

  // Auto-growing input: one row when empty, grows with content up to the
  // CSS max-h-40 clamp.
  useLayoutEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${el.scrollHeight}px`;
  }, [draft]);

  const onKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        // Match the Send button's affordance: Enter is inert while
        // disconnected (the reconnect banner is the call to action), instead
        // of stacking 'not connected' error rows per keypress.
        if (connState !== 'open') return;
        if (submit(draft)) setDraft('');
      }
    },
    [connState, draft, submit],
  );

  const pickPrompt = useCallback((text: string) => {
    setDraft(text);
    textareaRef.current?.focus();
  }, []);

  const entries = useMemo(() => groupTranscript(items), [items]);
  const lastItem = items[items.length - 1];
  const lastIsToolRun = lastItem?.kind === 'tool';
  const showThinking =
    busy &&
    !lastIsToolRun &&
    !(lastItem?.kind === 'assistant' && lastItem.streaming);
  const showHint = inputFocused && draft.length === 0;

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

      <div className="relative min-h-0 flex-1">
        <div
          ref={scrollRef}
          onScroll={onScroll}
          className="h-full overflow-y-auto px-3 py-3"
        >
          {items.length === 0 ? (
            <EmptyState onPick={pickPrompt} />
          ) : (
            <div className="flex flex-col gap-3">
              {entries.map((entry, i) =>
                entry.kind === 'tools' ? (
                  <ToolGroupRow
                    key={i}
                    group={entry}
                    running={busy && i === entries.length - 1}
                  />
                ) : (
                  <TranscriptRow key={i} item={entry} />
                ),
              )}
              {showThinking && (
                <div className="px-1 duration-300 animate-in fade-in">
                  <span className="text-shimmer text-xs font-medium">
                    Thinking…
                  </span>
                </div>
              )}
            </div>
          )}
        </div>

        {jumpVisible && (
          <Button
            variant="outline"
            size="sm"
            onClick={jumpToLatest}
            className="absolute bottom-3 left-1/2 h-7 -translate-x-1/2 rounded-full px-3 text-xs shadow-sm duration-200 animate-in fade-in slide-in-from-bottom-1"
          >
            <ArrowDown className="size-3" />
            Jump to latest
          </Button>
        )}
      </div>

      <div className="shrink-0 border-t border-border p-2">
        {connState === 'closed' && (
          <div className="mb-2 flex items-center justify-between gap-2 rounded-md border border-border bg-muted/50 px-2 py-1.5 text-xs text-muted-foreground duration-200 animate-in fade-in">
            <span>Disconnected</span>
            <Button
              variant="outline"
              size="sm"
              className="h-6 px-2 text-xs"
              onClick={() => setGeneration((g) => g + 1)}
            >
              Reconnect
            </Button>
          </div>
        )}
        {connState === 'no-workspace' && (
          <div className="mb-2 rounded-md border border-border bg-muted/50 px-2 py-1.5 text-xs text-muted-foreground duration-200 animate-in fade-in">
            No workspace selected.
          </div>
        )}

        <div className="flex items-end gap-2 rounded-md border border-border bg-card px-2 py-1.5 focus-within:ring-1 focus-within:ring-ring/50">
          <textarea
            ref={textareaRef}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            onFocus={() => setInputFocused(true)}
            onBlur={() => setInputFocused(false)}
            rows={1}
            placeholder="Message the agent…"
            className="max-h-40 min-h-0 flex-1 resize-none overflow-y-auto bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground/60"
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
                if (submit(draft)) setDraft('');
              }}
              disabled={draft.trim().length === 0 || connState !== 'open'}
              aria-label="Send message"
              title="Send"
            >
              <ArrowUp className="size-3.5" />
            </Button>
          )}
        </div>

        {(statusText || showHint) && (
          <div className="flex items-center justify-between gap-2 px-1 pt-1">
            <span className="font-mono text-[10px] text-muted-foreground">
              {statusText}
            </span>
            {showHint && (
              <span className="text-[10px] whitespace-nowrap text-muted-foreground/50">
                Enter to send · Shift+Enter for newline
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function EmptyState({ onPick }: { onPick: (text: string) => void }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 px-6 text-center duration-300 animate-in fade-in">
      <div className="rounded-xl bg-muted p-3">
        <Sparkles className="size-5 text-primary" />
      </div>
      <div>
        <div className="text-sm font-medium text-foreground">Tango Agent</div>
        <p className="mt-1 max-w-56 text-xs leading-relaxed text-muted-foreground">
          Designs on the canvas, builds for the simulator — ask for anything
          in between.
        </p>
      </div>
      <div className="flex max-w-full flex-wrap justify-center gap-1.5 pt-1">
        {EXAMPLE_PROMPTS.map((prompt) => (
          <Button
            key={prompt}
            variant="outline"
            size="sm"
            onClick={() => onPick(prompt)}
            className="h-7 rounded-full px-3 text-xs font-normal"
          >
            {prompt}
          </Button>
        ))}
      </div>
    </div>
  );
}

// Non-tool rows. memo works because groupTranscript passes these through by
// reference — only the streaming assistant bubble changes identity per delta.
const TranscriptRow = memo(function TranscriptRow({
  item,
}: {
  item: Exclude<TranscriptEntry, ToolsGroup>;
}) {
  if (item.kind === 'user') {
    return (
      <div className="max-w-[85%] self-end rounded-lg bg-primary/10 px-3 py-1.5 text-sm whitespace-pre-wrap text-foreground duration-200 animate-in fade-in slide-in-from-bottom-1">
        {item.text}
      </div>
    );
  }
  if (item.kind === 'assistant') {
    return (
      <div className="mr-4 px-1 duration-200 animate-in fade-in slide-in-from-bottom-1">
        <AgentMarkdown text={item.text} />
        {item.streaming && (
          <span className="mt-1 inline-block h-3.5 w-1 animate-pulse rounded-[1px] bg-primary" />
        )}
      </div>
    );
  }
  if (item.kind === 'meta') {
    return (
      <div className="self-end px-1 font-mono text-[10px] text-muted-foreground/70 duration-200 animate-in fade-in">
        {item.text}
      </div>
    );
  }
  return (
    <div
      className={cn(
        'flex items-start gap-1.5 rounded-md border border-destructive/20 bg-destructive/10 px-2 py-1.5 text-xs text-destructive',
        'duration-200 animate-in fade-in slide-in-from-bottom-1',
      )}
    >
      <CircleAlert className="mt-0.5 size-3 shrink-0" />
      <span className="min-w-0 break-words">{item.text}</span>
    </div>
  );
});

// A run of consecutive tool calls: tight stack behind a subtle left rail.
// Groups are rebuilt every render, so equality compares the tool items by
// reference — appended tools re-render only this group.
const ToolGroupRow = memo(
  function ToolGroupRow({
    group,
    running,
  }: {
    group: ToolsGroup;
    running: boolean;
  }) {
    return (
      <div className="ml-1 flex flex-col gap-1 border-l border-border pl-2">
        {group.items.map((item, i) => (
          <ToolRow
            key={i}
            item={item}
            running={running && i === group.items.length - 1}
          />
        ))}
      </div>
    );
  },
  (prev, next) =>
    prev.running === next.running &&
    prev.group.items.length === next.group.items.length &&
    prev.group.items.every((item, i) => item === next.group.items[i]),
);

const ToolRow = memo(function ToolRow({
  item,
  running,
}: {
  item: ToolItem;
  running: boolean;
}) {
  const Icon = toolIcon(item.name);
  return (
    <div className="flex items-center gap-1.5 text-xs text-muted-foreground duration-200 animate-in fade-in slide-in-from-bottom-1">
      {running ? (
        <Loader2 className="size-3 shrink-0 animate-spin text-primary" />
      ) : (
        <Icon className="size-3 shrink-0" />
      )}
      <span className="shrink-0 font-medium">{item.name}</span>
      {item.detail && (
        <span className="min-w-0 truncate font-mono text-[11px] text-muted-foreground/70">
          {item.detail}
        </span>
      )}
    </div>
  );
});
