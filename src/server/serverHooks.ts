// Cross-context hook registry.
//
// Next.js loads route handlers in a module graph that's separate from the
// custom server's (server.ts) graph. That means anything held in module-level
// state — the pty `activeSockets` Set, the canvas cache, etc. — is invisible
// to route handlers. This file uses `globalThis` as a process-wide registry
// so hubs registered in server.ts's graph can be invoked from the route-
// handler graph.
//
// Don't add new hooks here unless you've hit the dual-context problem. For
// data, prefer reading from disk or environment.

import type { UISpec } from '@/lib/uiMockProtocol';

const HOOKS_KEY = '__tangoServerHooks__';

export type ServerHooks = {
  broadcastWorkspaceChanged?: () => void;
  broadcastTerminalAgentChanged?: () => void;
  // Same broadcasts, but for the built-in agent's /ws/agent hub (hooks are
  // single-subscriber, so the agent bridge gets its own names; workspaceState
  // calls both).
  agentBroadcastWorkspaceChanged?: () => void;
  agentBroadcastTerminalAgentChanged?: () => void;
  resetUiMock?: () => void;
  // Read the live design-spec cache / active screen from the route-handler
  // graph (registered by uiMockBridge in server.ts's graph).
  getUiMockSpec?: () => UISpec;
  getUiMockActiveScreen?: () => string | null;
  // Replace the live design spec from the route-handler graph (fast import).
  // Routes through uiMockBridge's cacheChanged() so browsers, the preview
  // host, and the write-behind persist all see the change.
  setUiMockSpec?: (spec: UISpec) => void;
  // Number of connected /ws/preview clients (registered by previewBridge).
  previewClientCount?: () => number;
};

function getHooks(): ServerHooks {
  const g = globalThis as typeof globalThis & { [HOOKS_KEY]?: ServerHooks };
  if (!g[HOOKS_KEY]) g[HOOKS_KEY] = {};
  return g[HOOKS_KEY];
}

export function registerHook<K extends keyof ServerHooks>(
  name: K,
  fn: NonNullable<ServerHooks[K]>,
): void {
  getHooks()[name] = fn;
}

// Typed accessor for hooks that return values (the void-returning ones go
// through callHook, which swallows errors).
export function getHook<K extends keyof ServerHooks>(
  name: K,
): ServerHooks[K] | undefined {
  return getHooks()[name];
}

export function callHook<K extends keyof ServerHooks>(name: K): void {
  const fn = getHooks()[name];
  if (typeof fn === 'function') {
    try {
      (fn as () => void)();
    } catch (err) {
      console.warn(`tango: server hook "${String(name)}" threw`, err);
    }
  }
}
