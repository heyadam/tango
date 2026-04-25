// In-browser pubsub for "the active workspace changed." Subscribed to by
// Terminal (close+reopen WS) and SketchPanel (clear local cache, close+reopen
// canvas WS). Server-side state has already been swung by `setWorkspace` by
// the time we publish here.

export type WorkspaceChangedEvent = {
  path: string;
  name: string;
};

type Listener = (event: WorkspaceChangedEvent) => void;

const listeners = new Set<Listener>();

export const workspaceBus = {
  emit(event: WorkspaceChangedEvent): void {
    for (const fn of listeners) fn(event);
  },
  subscribe(cb: Listener): () => void {
    listeners.add(cb);
    return () => {
      listeners.delete(cb);
    };
  },
};
