'use client';

import { useState } from 'react';
import { useChat } from '@ai-sdk/react';
import {
  ImageUp,
  PanelLeftClose,
  PanelLeftOpen,
  Sparkles,
} from 'lucide-react';
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
import { cn } from '@/lib/utils';

type Props = {
  open: boolean;
  onToggle: () => void;
  onSendSketch: () => Promise<string | null>;
  sendBusy: boolean;
};

export default function AgentSidebar({
  open,
  onToggle,
  onSendSketch,
  sendBusy,
}: Props) {
  const { messages, sendMessage, status, stop } = useChat();
  const [sketchPath, setSketchPath] = useState<string | null>(null);
  const [sketchError, setSketchError] = useState<string | null>(null);

  const handleSubmit = (msg: PromptInputMessage) => {
    const text = msg.text.trim();
    if (!text) return;
    sendMessage({ text });
  };

  const handleSendSketch = async () => {
    setSketchError(null);
    try {
      const rel = await onSendSketch();
      if (rel) setSketchPath(rel);
    } catch (e) {
      setSketchError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <aside
      className={cn(
        'flex h-full shrink-0 flex-col overflow-hidden border-r border-neutral-800 bg-neutral-950 transition-[width] duration-200 ease-out',
        open ? 'w-[380px]' : 'w-12',
      )}
    >
      <div className="flex h-12 shrink-0 items-center justify-between border-b border-neutral-800 px-2">
        <Button
          variant="ghost"
          size="icon"
          onClick={onToggle}
          aria-label={open ? 'Collapse agent sidebar' : 'Expand agent sidebar'}
          className="size-8 text-neutral-400 hover:text-neutral-100"
        >
          {open ? (
            <PanelLeftClose className="size-4" />
          ) : (
            <PanelLeftOpen className="size-4" />
          )}
        </Button>
        {open && (
          <>
            <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-300">
              <Sparkles className="size-3.5 text-neutral-400" />
              <span>Agent</span>
            </div>
            <Button
              variant="ghost"
              size="sm"
              onClick={handleSendSketch}
              disabled={sendBusy}
              title="Send the canvas as a PNG to Claude in the terminal"
              className="h-8 gap-1.5 px-2 text-xs text-neutral-300 hover:text-neutral-100"
            >
              <ImageUp className="size-3.5" />
              {sendBusy ? 'Sending…' : 'Send sketch'}
            </Button>
          </>
        )}
      </div>

      {open && (
        <>
          <div className="relative flex min-h-0 flex-1 flex-col">
            <Conversation>
              <ConversationContent className="gap-6 px-3 py-4">
                {messages.length === 0 ? (
                  <ConversationEmptyState
                    title="Talk to the agent"
                    description="Ask about the canvas, brainstorm, or hit Send sketch to share it with Claude in the terminal."
                    icon={<Sparkles className="size-6" />}
                  />
                ) : (
                  messages.map((m) => (
                    <Message from={m.role} key={m.id}>
                      <MessageContent>
                        {m.parts.map((part, i) =>
                          part.type === 'text' ? (
                            <MessageResponse key={i}>{part.text}</MessageResponse>
                          ) : null,
                        )}
                      </MessageContent>
                    </Message>
                  ))
                )}
              </ConversationContent>
              <ConversationScrollButton />
            </Conversation>
          </div>

          {(sketchPath || sketchError) && (
            <div className="shrink-0 border-t border-neutral-800 px-3 py-1.5 font-mono text-[10px]">
              {sketchError ? (
                <span className="text-red-400">{sketchError}</span>
              ) : (
                <span className="text-neutral-500">sent {sketchPath}</span>
              )}
            </div>
          )}

          <div className="shrink-0 border-t border-neutral-800 p-3">
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
