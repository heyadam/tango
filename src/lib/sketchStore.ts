// In-memory + localStorage cache of the current Excalidraw scene, kept as the
// already-serialized JSON string produced by serializeAsJSON.
//
// Lives outside the React tree so a future in-process MCP tool (see
// CLAUDE.md vision §2) can read it without crawling component state.
// Until that lands the store is browser-only; mirroring to the server is a
// later concern.

const KEY = 'tango.sketch.current';

type Listener = (json: string | null) => void;

let cached: string | null | undefined;
const listeners = new Set<Listener>();

function readFromStorage(): string | null {
  if (typeof window === 'undefined') return null;
  try {
    return window.localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

export const sketchStore = {
  getCurrent(): string | null {
    if (cached === undefined) cached = readFromStorage();
    return cached;
  },

  setCurrent(json: string): void {
    cached = json;
    if (typeof window !== 'undefined') {
      try {
        window.localStorage.setItem(KEY, json);
      } catch {
        // quota / private browsing — fall back to in-memory only
      }
    }
    for (const fn of listeners) fn(cached);
  },

  subscribe(cb: Listener): () => void {
    listeners.add(cb);
    return () => {
      listeners.delete(cb);
    };
  },
};
