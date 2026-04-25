import http from 'node:http';
import next from 'next';
import { WebSocketServer } from 'ws';
import { attachPty } from './src/server/pty';

const dev = process.env.NODE_ENV !== 'production';
const hostname = process.env.HOST ?? 'localhost';
const port = Number(process.env.PORT ?? 3000);

const app = next({ dev, hostname, port });

const TERMINAL_PATH = '/ws/terminal';

app.prepare().then(() => {
  const handle = app.getRequestHandler();
  const upgradeHandle = app.getUpgradeHandler();

  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
      console.error('next handler error', err);
      res.statusCode = 500;
      res.end('internal server error');
    });
  });

  const wss = new WebSocketServer({ noServer: true });
  wss.on('connection', (ws) => {
    attachPty(ws);
  });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    if (url.pathname === TERMINAL_PATH) {
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req);
      });
      return;
    }
    upgradeHandle(req, socket, head);
  });

  server.listen(port, () => {
    console.log(`▲ tango ready on http://${hostname}:${port}`);
  });
});
