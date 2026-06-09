// localStorage-backed cache of the design spec.
// Survives a refresh; the server cache in uiMockBridge is the cross-process
// source of truth and overwrites this on (re)connect.

import { EMPTY_SPEC, type UISpec } from './uiMockProtocol';

const KEY = 'tango:ui-mock:v1';

function isSpec(value: unknown): value is UISpec {
  if (!value || typeof value !== 'object') return false;
  const obj = value as Record<string, unknown>;
  return Array.isArray(obj.screens);
}

export const uiMockStore = {
  load(): UISpec {
    if (typeof window === 'undefined') return EMPTY_SPEC;
    try {
      const raw = window.localStorage.getItem(KEY);
      if (!raw) return EMPTY_SPEC;
      const parsed = JSON.parse(raw) as unknown;
      if (isSpec(parsed)) return parsed;
    } catch {
      // malformed — fall through to empty
    }
    return EMPTY_SPEC;
  },
  save(spec: UISpec): void {
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.setItem(KEY, JSON.stringify(spec));
    } catch {
      // quota / disabled — ignore
    }
  },
  clear(): void {
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.removeItem(KEY);
    } catch {
      // ignore
    }
  },
};
