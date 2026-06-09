// Single helper for client-side WebSocket connects. Picks ws/wss from the
// page's protocol and reads the host off `window.location`, so the Electron
// loopback / proxied-dev cases only need to be fixed here.

export function openWS(path: string): WebSocket {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return new WebSocket(`${proto}//${window.location.host}${path}`);
}
