@AGENTS.md

# tango

Split-pane web app: arbitrary content on the left, an interactive xterm.js terminal on the right backed by a real shell via `node-pty`. Designed to grow into a host for codex / claude-code agents that act on the left panel.

Stack: **Next.js 16 (App Router) + React 19 + Tailwind v4**, custom Node server, WebSocket bridge to `node-pty`. Will eventually be packaged as an Electron app — keep that path open (no Vercel-only assumptions, no edge runtime).

## Run / build

```
npm run dev      # tsx server.ts on :3000
npm run build    # next build (server stays the same)
npm start        # production server
```

The dev script runs the **custom server**, not `next dev`. Do not change to `next dev` — it will break the WebSocket bridge.

## Architecture (non-obvious bits)

```
browser  ──HTTP──►  Next request handler         ┐
                                                 ├── server.ts (one Node process)
browser  ──WS────►  /ws/terminal → attachPty ────┘
                                ↓
                         node-pty.spawn($SHELL)
```

- **Custom server** ([server.ts](server.ts)): hosts both Next and a `WebSocketServer({ noServer: true })`. The `'upgrade'` listener routes only `/ws/terminal` to our WS — everything else (HMR, etc.) is forwarded to `app.getUpgradeHandler()`. Both `getRequestHandler()` and `getUpgradeHandler()` **must be called inside `app.prepare().then(...)`**, never at module top level — they throw "prepare() must be called" otherwise.

- **PTY bridge** ([src/server/pty.ts](src/server/pty.ts)): one `node-pty` process per WS connection. Wire protocol:
  - server → client: **binary** frames = raw pty bytes
  - client → server, **binary**: raw keystrokes → `pty.write`
  - client → server, **text** (JSON): control messages, currently `{type:"resize", cols, rows}`

  Keep new control messages on the text channel; never multiplex into the binary stream.

- **terminalBus** ([src/lib/terminalBus.ts](src/lib/terminalBus.ts)): in-browser pubsub seam between the left panel and the Terminal component. Public: `sendToTerminal(text)`, `onTerminalOutput(cb) → unsubscribe`. The `_onSend` / `_emitOutput` underscore methods are wired by `Terminal.tsx` only — do not call from feature code. In dev the bus is also exposed at `window.__tangoBus` for console testing.

- **Terminal component** ([src/components/Terminal.tsx](src/components/Terminal.tsx)): must stay client-only. Imported via `dynamic(() => import('@/components/Terminal'), { ssr: false })` in [src/app/page.tsx](src/app/page.tsx). xterm.js touches the DOM and explodes on SSR. Resize is a debounced `ResizeObserver` (50ms) that calls `fitAddon.fit()` then sends a JSON resize.

## Layout

`react-resizable-panels` is **v4**, which renamed everything. Do not use v3 names from training data:

| v3 (training data)    | v4 (this project) |
|-----------------------|-------------------|
| `PanelGroup`          | `Group`           |
| `PanelResizeHandle`   | `Separator`       |
| `direction="..."`     | `orientation="..."` |
| `autoSaveId`          | `defaultLayout` + `onLayoutChanged` (manual storage) |

Sizes accept strings with units (`"35%"`, `"400px"`) or bare numbers (percent).

## node-pty caveat (will bite again)

`npm install` extracts `node_modules/node-pty/prebuilds/<plat>/spawn-helper` **without** the executable bit, which makes `pty.spawn` crash with `posix_spawnp failed` at runtime — not at install time. There's a `postinstall` script ([scripts/fix-node-pty.js](scripts/fix-node-pty.js)) that re-applies `chmod +x`. If a fresh clone errors with `posix_spawnp failed`, run `node scripts/fix-node-pty.js` (or `npm rebuild`).

## Conventions

- **Don't add an MCP server yet.** That layer is planned for the codex/claude-code phase (see vision below). For now everything goes through `terminalBus`.
- **Don't bypass `terminalBus`** by reaching into the WebSocket from outside `Terminal.tsx`. The bus is the seam; future features (recording, multi-tab, MCP) will hook it.
- **No `next dev`, no Vercel adapters, no edge runtime.** Custom Node server is load-bearing because the WS lives in-process, and Electron will swap the WS for IPC against the same `attachPty`-shaped surface.
- **Strict Mode is on.** The Terminal effect runs twice in dev → you'll see one harmless "WebSocket is closed before the connection is established" warning per mount. Don't "fix" by disabling Strict Mode.
- ANSI stripping in [LeftPanel.tsx](src/components/LeftPanel.tsx) handles CSI/OSC/Fp/Fe + backspaces. If a new feature needs full terminal state, parse the byte stream there — don't try to make the regex perfect.

## Vision (so future changes don't paint into a corner)

1. **Now:** terminal works, bus seam exists.
2. **Next:** wire codex / claude-code inside the terminal. The agent will manipulate the left panel via a **local MCP server** added in-process to `server.ts`, exposing typed tools (`update_left_panel`, `get_state`, …). MCP supplements the bus — the bus stays for in-app glue.
3. **Later:** package as Electron. The renderer drops the WS and calls `attachPty`-equivalent over IPC; the rest of the React tree is unchanged.

## Files that matter

- [server.ts](server.ts) — Next + WS upgrade routing
- [src/server/pty.ts](src/server/pty.ts) — node-pty ↔ WS bridge
- [src/components/Terminal.tsx](src/components/Terminal.tsx) — xterm + FitAddon + WS + bus wiring
- [src/lib/terminalBus.ts](src/lib/terminalBus.ts) — in-app seam
- [src/app/page.tsx](src/app/page.tsx) — split-pane layout
- [src/components/LeftPanel.tsx](src/components/LeftPanel.tsx) — placeholder + bus consumer
- [scripts/fix-node-pty.js](scripts/fix-node-pty.js) — postinstall workaround
