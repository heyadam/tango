'use client';

import { useState } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { ImageUp, Sparkles } from 'lucide-react';
import {
  Conversation,
  ConversationContent,
  ConversationEmptyState,
  ConversationScrollButton,
} from '@/components/ai-elements/conversation';
import {
  Message,
  MessageContent,
  MessageResponse,
} from '@/components/ai-elements/message';
import {
  PromptInput,
  PromptInputBody,
  PromptInputFooter,
  PromptInputSubmit,
  PromptInputTextarea,
  PromptInputTools,
  type PromptInputMessage,
} from '@/components/ai-elements/prompt-input';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { cn } from '@/lib/utils';

type Props = {
  open: boolean;
  onSendSketch: (caption?: string) => Promise<string | null>;
  sendBusy: boolean;
  canSendSketch?: boolean;
};

export default function AgentSidebar({
  open,
  onSendSketch,
  sendBusy,
  canSendSketch = true,
}: Props) {
  // Talk to the UI-controller agent (cursor_move / cursor_click / terminal_type
  // / dom_inspect MCP tools). The agent doesn't draft content itself — it
  // delegates to terminal-Claude via terminal_type and visibly moves the
  // shared cursor through AgentCursorOverlay so the user can watch.
  const { messages, sendMessage, status, stop } = useChat({
    transport: new DefaultChatTransport({ api: '/api/agent' }),
  });
  const [sketchPath, setSketchPath] = useState<string | null>(null);
  const [sketchError, setSketchError] = useState<string | null>(null);
  const [sketchCaption, setSketchCaption] = useState('');

  const handleSubmit = (msg: PromptInputMessage) => {
    const text = msg.text.trim();
    if (!text) return;
    sendMessage({ text });
  };

  const handleSendSketch = async () => {
    setSketchError(null);
    try {
      const captionTrimmed = sketchCaption.trim();
      const rel = await onSendSketch(captionTrimmed || undefined);
      if (rel) {
        setSketchPath(rel);
        setSketchCaption('');
      }
    } catch (e) {
      setSketchError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <aside
      aria-hidden={!open}
      className={cn(
        'flex h-full shrink-0 flex-col overflow-hidden bg-background transition-[width] duration-200 ease-out',
        open ? 'w-[380px] border-r border-border' : 'w-0',
      )}
    >
      <div className="flex h-12 shrink-0 items-center justify-between border-b border-border px-2">
        {open && (
          <>
            <div className="flex items-center gap-1.5 text-xs font-medium text-foreground">
              <Sparkles className="size-3.5 text-muted-foreground" />
              <span>Agent</span>
            </div>
            {canSendSketch && (
              <Button
                variant="ghost"
                size="sm"
                onClick={handleSendSketch}
                disabled={sendBusy}
                title="Send the canvas as a PNG to Claude in the terminal"
                className="h-8 gap-1.5 px-2 text-xs"
              >
                <ImageUp className="size-3.5" />
                {sendBusy ? 'Sending…' : 'Send sketch'}
              </Button>
            )}
          </>
        )}
      </div>

      {open && canSendSketch && (
        <div className="shrink-0 border-b border-border px-2 py-1.5">
          <Input
            type="text"
            value={sketchCaption}
            onChange={(e) => setSketchCaption(e.target.value)}
            placeholder="Note (optional) — appears in tango-memory.md"
            disabled={sendBusy}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                if (!sendBusy) void handleSendSketch();
              }
            }}
            maxLength={240}
            className="h-7 text-xs"
          />
        </div>
      )}

      {open && (
        <>
          <div className="relative flex min-h-0 flex-1 flex-col">
            <Conversation>
              <ConversationContent className="gap-6 px-3 py-4">
                {messages.length === 0 ? (
                  <ConversationEmptyState
                    title="Talk to the agent"
                    description={
                      canSendSketch
                        ? 'Ask about the canvas, brainstorm, or hit Send sketch to share it with Claude in the terminal.'
                        : 'Ask the agent to delegate work to Claude in the terminal.'
                    }
                    icon={<Sparkles className="size-6" />}
                  />
                ) : (
                  messages.map((m) => (
                    <Message from={m.role} key={m.id}>
                      <MessageContent>
                        {m.parts.map((part, i) => {
                          if (part.type === 'text') {
                            return (
                              <MessageResponse key={i}>
                                {part.text}
                              </MessageResponse>
                            );
                          }
                          if (
                            typeof part.type === 'string' &&
                            part.type.startsWith('tool-')
                          ) {
                            const name = part.type.slice('tool-'.length);
                            const p = part as unknown as {
                              state?: string;
                              input?: unknown;
                              output?: unknown;
                            };
                            return (
                              <div
                                key={i}
                                className="rounded border border-border bg-muted px-2 py-1 font-mono text-[10px] text-foreground"
                              >
                                <div className="text-violet-700">
                                  {name}
                                  {p.state ? ` · ${p.state}` : ''}
                                </div>
                                {p.input !== undefined && (
                                  <pre className="mt-0.5 whitespace-pre-wrap text-muted-foreground">
                                    {JSON.stringify(p.input, null, 2)}
                                  </pre>
                                )}
                                {p.output !== undefined && (
                                  <pre className="mt-0.5 whitespace-pre-wrap text-muted-foreground/70">
                                    → {JSON.stringify(p.output, null, 2)}
                                  </pre>
                                )}
                              </div>
                            );
                          }
                          return null;
                        })}
                      </MessageContent>
                    </Message>
                  ))
                )}
              </ConversationContent>
              <ConversationScrollButton />
            </Conversation>
          </div>

          {(sketchPath || sketchError) && (
            <div className="shrink-0 border-t border-border px-3 py-1.5 font-mono text-[10px]">
              {sketchError ? (
                <span className="text-pink-700">{sketchError}</span>
              ) : (
                <span className="text-muted-foreground">sent {sketchPath}</span>
              )}
            </div>
          )}

          <div className="shrink-0 border-t border-border p-3">
            <PromptInput onSubmit={handleSubmit}>
              <PromptInputBody>
                <PromptInputTextarea placeholder="Message the agent…" />
              </PromptInputBody>
              <PromptInputFooter>
                <PromptInputTools />
                <PromptInputSubmit status={status} onStop={stop} />
              </PromptInputFooter>
            </PromptInput>
          </div>
        </>
      )}
    </aside>
  );
}
