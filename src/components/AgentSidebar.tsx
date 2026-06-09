'use client';

import { useMemo } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { Sparkles } from 'lucide-react';
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
import {
  TERMINAL_AGENTS,
  type TerminalAgentId,
} from '@/lib/terminalAgent';
import { cn } from '@/lib/utils';

type Props = {
  open: boolean;
  terminalAgent: TerminalAgentId;
};

export default function AgentSidebar({ open, terminalAgent }: Props) {
  // Talk to the UI-controller agent (cursor_move / cursor_click / terminal_type
  // / dom_inspect MCP tools). The agent doesn't draft content itself — it
  // delegates to the active terminal agent via terminal_type and visibly moves the
  // shared cursor through AgentCursorOverlay so the user can watch.
  const terminalAgentMeta = TERMINAL_AGENTS[terminalAgent];
  const transport = useMemo(
    () =>
      new DefaultChatTransport({
        api: '/api/agent',
        body: { terminalAgent },
      }),
    [terminalAgent],
  );
  const { messages, sendMessage, status, stop } = useChat({
    transport,
  });

  const handleSubmit = (msg: PromptInputMessage) => {
    const text = msg.text.trim();
    if (!text) return;
    sendMessage({ text });
  };

  return (
    <aside
      aria-hidden={!open}
      className={cn(
        'flex h-full shrink-0 flex-col overflow-hidden bg-background transition-[width] duration-200 ease-out',
        open ? 'w-[380px] border-r border-border' : 'w-0',
      )}
    >
      <PanelHeader icon={Sparkles} title="Agent" />

      <div className="relative flex min-h-0 flex-1 flex-col">
        <Conversation>
          <ConversationContent className="gap-6 px-3 py-4">
            {messages.length === 0 ? (
              <ConversationEmptyState
                title="Talk to the agent"
                description={`Ask the agent to delegate work to ${terminalAgentMeta.shortLabel} in the terminal.`}
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
                            <div className="text-primary">
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
    </aside>
  );
}
