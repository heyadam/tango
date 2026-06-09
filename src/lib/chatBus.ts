// Pubsub seam between feature panels (SketchPanel, UIPanel, MoodboardPanel)
// and the ChatPanel. Mirrors terminalBus.ts — feature code calls
// `chatBus.send(...)`, ChatPanel registers via `_onSend(cb)` and forwards the
// text to its useChat sendMessage.

type SendOpts = { autosubmit?: boolean };
type SendListener = (text: string, opts?: SendOpts) => void;

const sendListeners = new Set<SendListener>();

export const chatBus = {
  // Public API for the rest of the app:

  // Default behavior is "autosubmit" — feature panels pushing handoff
  // prompts in want them to actually fire, mirroring terminalBus.submitToTerminal.
  send(text: string, opts: SendOpts = { autosubmit: true }): void {
    for (const fn of sendListeners) fn(text, opts);
  },

  // Wired by ChatPanel only:

  _onSend(cb: SendListener): () => void {
    sendListeners.add(cb);
    return () => {
      sendListeners.delete(cb);
    };
  },
};

declare global {
  interface Window {
    __tangoChatBus?: typeof chatBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoChatBus = chatBus;
}
