// Browser-side pub/sub seam for the transmit-to-terminal scan effect.
// Mirrors terminalBus / canvasBus. Fires when an image-bearing handoff
// (today: MoodboardPanel "Send to Claude") goes to the terminal so
// TransmitOverlay can play a brief scan shader over the image.

export type TransmitEvent = {
  src: string;
  label?: string;
};

type Listener = (event: TransmitEvent) => void;

const listeners = new Set<Listener>();

export const transmitBus = {
  show(event: TransmitEvent): void {
    for (const fn of listeners) fn(event);
  },

  subscribe(cb: Listener): () => void {
    listeners.add(cb);
    return () => listeners.delete(cb);
  },
};

declare global {
  interface Window {
    __tangoTransmitBus?: typeof transmitBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoTransmitBus = transmitBus;
}
