// Pure transcript-shaping helpers for the built-in agent chat panel.
// AgentPanel accumulates a flat append-only list of TranscriptItems from the
// /ws/agent frames; groupTranscript folds consecutive tool calls into one
// visual group so the transcript reads as turns, not a tool-call log.
// Browser-safe and side-effect free — unit tested in agentTranscript.test.ts.

// pending: the model is still composing this tool call's input (tool_pending
// frame); the item is replaced by the real one when the tool_use frame lands.
export type ToolItem = {
  kind: 'tool';
  name: string;
  detail: string;
  pending?: boolean;
};

export type TranscriptItem =
  | { kind: 'user'; text: string }
  | { kind: 'task'; label: string; prompt: string }
  | { kind: 'assistant'; text: string; streaming: boolean }
  | ToolItem
  | { kind: 'meta'; text: string }
  | { kind: 'error'; text: string };

export type ToolsGroup = { kind: 'tools'; items: ToolItem[] };

// What the panel renders: every non-tool item passes through by reference
// (load-bearing for React.memo — untouched items keep identity), and each
// maximal run of consecutive tools becomes a single ToolsGroup.
export type TranscriptEntry = Exclude<TranscriptItem, ToolItem> | ToolsGroup;

export function groupTranscript(items: TranscriptItem[]): TranscriptEntry[] {
  const entries: TranscriptEntry[] = [];
  for (const item of items) {
    if (item.kind === 'tool') {
      const last = entries[entries.length - 1];
      if (last && last.kind === 'tools') {
        last.items.push(item);
      } else {
        entries.push({ kind: 'tools', items: [item] });
      }
    } else {
      entries.push(item);
    }
  }
  return entries;
}
