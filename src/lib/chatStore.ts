// localStorage-backed cache of the chat transcript, keyed by workspace path.
// Survives a refresh per workspace; switching workspaces yields a fresh chat.
// Capped at MAX_MESSAGES + MAX_BYTES so a runaway tool-result transcript can't
// blow out the localStorage quota.

import type { UIMessage } from 'ai';

export const MAX_MESSAGES = 200;
export const MAX_BYTES = 1_000_000;

export function chatKey(workspacePath: string): string {
  return `tango:chat:v1:${workspacePath}`;
}

function isMessageArray(value: unknown): value is UIMessage[] {
  if (!Array.isArray(value)) return false;
  for (const m of value) {
    if (!m || typeof m !== 'object') return false;
    const obj = m as Record<string, unknown>;
    if (typeof obj.id !== 'string') return false;
    if (typeof obj.role !== 'string') return false;
    if (!Array.isArray(obj.parts)) return false;
  }
  return true;
}

function trim(messages: UIMessage[]): UIMessage[] {
  let trimmed = messages;
  if (trimmed.length > MAX_MESSAGES) {
    trimmed = trimmed.slice(trimmed.length - MAX_MESSAGES);
  }
  // If still too big, drop oldest until under MAX_BYTES.
  let serialized = JSON.stringify(trimmed);
  while (serialized.length > MAX_BYTES && trimmed.length > 1) {
    trimmed = trimmed.slice(1);
    serialized = JSON.stringify(trimmed);
  }
  return trimmed;
}

export const chatStore = {
  load(workspacePath: string): UIMessage[] {
    if (typeof window === 'undefined') return [];
    if (!workspacePath) return [];
    try {
      const raw = window.localStorage.getItem(chatKey(workspacePath));
      if (!raw) return [];
      const parsed = JSON.parse(raw) as unknown;
      if (isMessageArray(parsed)) return parsed;
    } catch {
      // malformed or quota — fall through
    }
    return [];
  },

  save(workspacePath: string, messages: UIMessage[]): void {
    if (typeof window === 'undefined') return;
    if (!workspacePath) return;
    const out = trim(messages);
    try {
      window.localStorage.setItem(chatKey(workspacePath), JSON.stringify(out));
    } catch {
      // quota / disabled — ignore
    }
  },

  clear(workspacePath: string): void {
    if (typeof window === 'undefined') return;
    if (!workspacePath) return;
    try {
      window.localStorage.removeItem(chatKey(workspacePath));
    } catch {
      // ignore
    }
  },
};
