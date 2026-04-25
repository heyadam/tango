type SendListener = (text: string) => void;
type OutputListener = (data: string) => void;

const sendListeners = new Set<SendListener>();
const outputListeners = new Set<OutputListener>();

export const terminalBus = {
  // Public API for the rest of the app:

  sendToTerminal(text: string): void {
    for (const fn of sendListeners) fn(text);
  },

  submitToTerminal(text: string): void {
    for (const fn of sendListeners) fn(text);
    window.setTimeout(() => {
      for (const fn of sendListeners) fn('\r');
    }, 120);
  },

  onTerminalOutput(cb: OutputListener): () => void {
    outputListeners.add(cb);
    return () => outputListeners.delete(cb);
  },

  // Wired by the Terminal component only:

  _onSend(cb: SendListener): () => void {
    sendListeners.add(cb);
    return () => sendListeners.delete(cb);
  },

  _emitOutput(data: string): void {
    for (const fn of outputListeners) fn(data);
  },
};

declare global {
  interface Window {
    __tangoBus?: typeof terminalBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoBus = terminalBus;
}
