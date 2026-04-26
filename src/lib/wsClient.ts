// Single helper for the three client-side WebSocket connects. Picking ws/wss
// from the page's protocol and reading the host off `window.location` was
// duplicated in Terminal.tsx, SketchPanel.tsx, and AgentCursorOverlay.tsx;
// centralize it so the Electron loopback / proxied-dev cases only need to be
// fixed here.

export function openWS(path: string): WebSocket {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return new WebSocket(`${proto}//${window.location.host}${path}`);
}
