'use client';

import { useEffect, useRef } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { MessageSquare } from 'lucide-react';
import PanelHeader from '@/components/PanelHeader';
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
import { chatBus } from '@/lib/chatBus';
import { chatStore } from '@/lib/chatStore';

type Props = {
  workspacePath: string | null;
};

export default function ChatPanel({ workspacePath }: Props) {
  // Per-workspace chat: switching workspaces yields a fresh transcript.
  const chatId = workspacePath ?? '__no-workspace__';

  const { messages, sendMessage, setMessages, status, stop } = useChat({
    id: chatId,
    transport: new DefaultChatTransport({ api: '/api/chat' }),
  });

  // Hydrate from localStorage post-mount (avoids SSR mismatch — chatStore
  // touches window). Re-hydrates whenever the workspace changes.
  const hydratedFor = useRef<string | null>(null);
  useEffect(() => {
    if (!workspacePath) return;
    if (hydratedFor.current === workspacePath) return;
    hydratedFor.current = workspacePath;
    const saved = chatStore.load(workspacePath);
    if (saved.length > 0) setMessages(saved);
    else setMessages([]);
  }, [workspacePath, setMessages]);

  // Mirror messages back to localStorage as they change. Skip until hydration
  // has run for this workspace so we don't clobber saved state with [].
  useEffect(() => {
    if (!workspacePath) return;
    if (hydratedFor.current !== workspacePath) return;
    chatStore.save(workspacePath, messages);
  }, [messages, workspacePath]);

  // Bus seam — feature panels (SketchPanel, UIPanel, MoodboardPanel) push
  // prompts into chat without holding their own useChat reference.
  useEffect(() => {
    return chatBus._onSend((text) => {
      const trimmed = text.trim();
      if (!trimmed) return;
      sendMessage({ text: trimmed });
    });
  }, [sendMessage]);

  const handleSubmit = (msg: PromptInputMessage) => {
    const text = msg.text.trim();
    if (!text) return;
    sendMessage({ text });
  };

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <PanelHeader icon={MessageSquare} title="Chat" />

      <div className="relative flex min-h-0 flex-1 flex-col">
        <Conversation>
          <ConversationContent className="gap-6 px-3 py-4">
            {messages.length === 0 ? (
              <ConversationEmptyState
                title="Talk to tango"
                description="Sketch something, send it over, or just ask."
                icon={<MessageSquare className="size-6" />}
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
                        return (
                          <ToolCallView key={i} part={part as ToolPart} />
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

      <div className="shrink-0 border-t border-border p-3">
        <PromptInput onSubmit={handleSubmit}>
          <PromptInputBody>
            <PromptInputTextarea placeholder="Message tango…" />
          </PromptInputBody>
          <PromptInputFooter>
            <PromptInputTools />
            <PromptInputSubmit status={status} onStop={stop} />
          </PromptInputFooter>
        </PromptInput>
      </div>
    </div>
  );
}

type ToolPart = {
  type: string;
  state?: string;
  input?: unknown;
  output?: unknown;
};

function ToolCallView({ part }: { part: ToolPart }) {
  const name = part.type.slice('tool-'.length);

  // Special-case rendering for tools whose output is worth showing inline.
  const inline = inlineRender(name, part);

  return (
    <div className="rounded border border-border bg-muted px-2 py-1 font-mono text-[10px] text-foreground">
      <div className="text-primary">
        {name}
        {part.state ? ` · ${part.state}` : ''}
      </div>
      {part.input !== undefined && (
        <pre className="mt-0.5 whitespace-pre-wrap text-muted-foreground">
          {JSON.stringify(part.input, null, 2)}
        </pre>
      )}
      {inline ? (
        <div className="mt-1">{inline}</div>
      ) : part.output !== undefined ? (
        <pre className="mt-0.5 whitespace-pre-wrap text-muted-foreground/70">
          → {JSON.stringify(part.output, null, 2)}
        </pre>
      ) : null}
    </div>
  );
}

function inlineRender(name: string, part: ToolPart): React.ReactNode {
  if (part.output == null) return null;
  const out = part.output as Record<string, unknown>;

  if (name === 'screenshot_canvas') {
    const content = (out.content ?? []) as Array<{
      type?: string;
      data?: string;
      mimeType?: string;
    }>;
    const img = content.find((c) => c.type === 'image' && c.data);
    if (img?.data && img.mimeType) {
      return (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={`data:${img.mimeType};base64,${img.data}`}
          alt="canvas screenshot"
          className="max-h-48 rounded border border-border"
        />
      );
    }
  }

  if (name === 'vision_describe_canvas' && typeof out.description === 'string') {
    return (
      <div className="whitespace-pre-wrap font-sans text-[11px] text-foreground/90">
        {out.description}
      </div>
    );
  }

  if (name === 'ios_build_run') {
    const ok = out.ok;
    const stage = (out.stage as string | undefined) ?? '';
    const message = (out.message as string | undefined) ?? '';
    return (
      <div className="font-sans text-[11px]">
        <span className={ok ? 'text-foreground' : 'text-destructive'}>
          {ok ? '✓' : '✗'} {stage}
        </span>
        {message ? (
          <span className="ml-2 text-muted-foreground">{message}</span>
        ) : null}
      </div>
    );
  }

  return null;
}
