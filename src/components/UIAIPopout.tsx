'use client';

// The in-canvas "ask AI" card. Opened by the sparkle triggers in UIMockCanvas
// (selection bbox, active screen, layers-panel headers) and positioned by the
// canvas in wrapper coords — it never measures anything itself. Submission
// goes through terminalBus.submitTask so whichever agent panel is mounted
// (built-in chat or PTY) picks it up; the popout closes on submit and the
// sidebar becomes the single feedback locus.

import { useEffect, useRef, useState } from 'react';
import { ArrowUp, Sparkles } from 'lucide-react';
import { Button } from './ui/button';
import {
  PRESET_PREFILLS,
  buildCustomPrompt,
  buildVariationsPrompt,
  taskLabel,
} from '@/lib/agentTaskPrompts';
import {
  type AgentTask,
  terminalBus,
} from '@/lib/terminalBus';
import { TERMINAL_AGENTS } from '@/lib/terminalAgent';

// 4 rows of text-sm (20px line height) — the textarea auto-grows up to here.
const TEXTAREA_MAX_PX = 80;

type Props = {
  scope: AgentTask['scope'];
  position: { left: number; top: number };
  onClose: () => void;
};

export default function UIAIPopout({ scope, position, onClose }: Props) {
  const [draft, setDraft] = useState('');
  const [agentState, setAgentState] = useState(() =>
    terminalBus.getAgentState(),
  );
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  // Self-disable window for the hero button — preset chips only prefill, so
  // this is the one control that could rapid-fire duplicate tasks.
  const heroFiredAt = useRef(0);

  // Last-value replay: seed from getAgentState() (the subscription does not
  // invoke on subscribe), then track changes.
  useEffect(() => terminalBus.onAgentState(setAgentState), []);

  // Auto-grow 1→4 rows. Keyed on draft so prefill clicks resize too.
  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, TEXTAREA_MAX_PX)}px`;
  }, [draft]);

  // Busy never blocks — agentBridge's streaming-input queue handles mid-turn
  // pushes. Only a dead/absent agent disables send.
  const sendBlocked =
    agentState.kind === 'none' ||
    (agentState.kind === 'tango' && !agentState.connected);

  const submitVariations = () => {
    if (sendBlocked) return;
    const now = Date.now();
    if (now - heroFiredAt.current < 600) return;
    heroFiredAt.current = now;
    terminalBus.submitTask({
      prompt: buildVariationsPrompt(scope),
      label: taskLabel(scope, 'variations'),
      scope,
    });
    onClose();
  };

  const submitCustom = () => {
    if (draft.trim() === '' || sendBlocked) return;
    terminalBus.submitTask({
      prompt: buildCustomPrompt(scope, draft),
      label: taskLabel(scope, 'custom', draft),
      scope,
    });
    onClose();
  };

  const prefills =
    PRESET_PREFILLS[scope.kind === 'screen' ? 'screen' : 'nodes'];
  const count = scope.nodeIds?.length ?? 0;
  const scopeLabel =
    scope.kind === 'screen'
      ? `Screen · ${scope.screenTitle}`
      : `${count} element${count === 1 ? '' : 's'} · ${scope.screenTitle}`;

  let caption: { tone: 'muted' | 'destructive'; text: string } | null = null;
  if (agentState.kind === 'none') {
    caption = { tone: 'destructive', text: 'No agent connected.' };
  } else if (agentState.kind === 'tango' && !agentState.connected) {
    caption = {
      tone: 'destructive',
      text: 'Agent not connected — open the sidebar to reconnect.',
    };
  } else if (agentState.kind === 'tango' && agentState.busy) {
    caption = {
      tone: 'muted',
      text: 'Tango is busy — your request will queue.',
    };
  } else if (agentState.kind === 'pty') {
    caption = {
      tone: 'muted',
      text: `Sends to ${TERMINAL_AGENTS[agentState.agent].label}`,
    };
  }

  return (
    <div
      // Stop pointer events from reaching the canvas (which would clear the
      // anchored selection / start a drag).
      onPointerDown={(e) => e.stopPropagation()}
      className="absolute w-72 rounded-lg border border-border bg-card p-3 shadow-lg duration-150 animate-in fade-in zoom-in-95"
      style={position}
    >
      <div className="flex items-center gap-1.5">
        <Sparkles className="size-3.5 shrink-0 text-primary" />
        <span className="truncate text-xs text-muted-foreground">
          {scopeLabel}
        </span>
      </div>

      <Button
        variant="secondary"
        size="sm"
        className="mt-2 w-full"
        disabled={sendBlocked}
        onClick={submitVariations}
      >
        {scope.kind === 'screen'
          ? 'Generate 3 variations'
          : 'Generate 3 element variations'}
      </Button>

      <div className="mt-2 flex flex-wrap gap-1">
        {Object.entries(prefills).map(([label, prefill]) => (
          <button
            key={label}
            type="button"
            onClick={() => {
              setDraft(prefill);
              textareaRef.current?.focus();
            }}
            className="rounded-full border border-border px-2 py-0.5 text-xs text-muted-foreground hover:bg-accent"
          >
            {label}
          </button>
        ))}
      </div>

      <div className="mt-2 flex items-end gap-1.5">
        <textarea
          ref={textareaRef}
          autoFocus
          rows={1}
          value={draft}
          placeholder={
            scope.kind === 'screen'
              ? 'Ask the agent about this screen…'
              : 'Ask the agent about this selection…'
          }
          className="min-w-0 flex-1 resize-none bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              submitCustom();
            } else if (e.key === 'Escape') {
              // Close the popout only — the canvas's window listener never
              // sees this, so the anchored selection survives.
              e.stopPropagation();
              onClose();
            }
          }}
        />
        <button
          type="button"
          aria-label="Send to agent"
          disabled={draft.trim() === '' || sendBlocked}
          onClick={submitCustom}
          className="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground disabled:opacity-50"
        >
          <ArrowUp className="size-3.5" />
        </button>
      </div>

      {caption && (
        <p
          className={
            caption.tone === 'destructive'
              ? 'mt-2 text-[10px] text-destructive'
              : 'mt-2 text-[10px] text-muted-foreground'
          }
        >
          {caption.text}
        </p>
      )}
    </div>
  );
}
