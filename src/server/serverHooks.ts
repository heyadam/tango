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

const HOOKS_KEY = '__tangoServerHooks__';

export type ServerHooks = {
  broadcastWorkspaceChanged?: () => void;
  resetCanvas?: () => void;
  resetUiMock?: () => void;
  resetIosScan?: () => void;
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
