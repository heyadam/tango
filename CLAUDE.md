@AGENTS.md

# tango

Split-pane web app: arbitrary content on the left, an interactive xterm.js terminal on the right backed by a real shell via `node-pty`. Designed to grow into a host for codex / claude-code agents that act on the left panel.

Stack: **Next.js 16 (App Router) + React 19 + Tailwind v4**, custom Node server, WebSocket bridge to `node-pty`, Excalidraw on the left for designer mode, in-process MCP server giving Claude tools to drive the canvas. Will eventually be packaged as an Electron app — keep that path open (no Vercel-only assumptions, no edge runtime).

The repo and the workspace Claude operates in are **separate directories** by design. This repo is for tango itself; Claude lands in `~/dev/tangotest` (override via `TANGO_WORKSPACE`). See **Workspace** below.

## Run / build

```
npm run dev      # tsx server.ts on :3000
npm run build    # next build (server stays the same)
npm start        # production server
```

The dev script runs the **custom server**, not `next dev`. Do not change to `next dev` — it will break the WebSocket bridge.

On boot the server provisions the workspace dir (creates `~/dev/tangotest`, writes `.mcp.json`, merges `.claude/settings.json`, ensures `design-scratch/`). Wipe the dir and the next `npm run dev` recreates it.

## Architecture (non-obvious bits)

```
browser ──HTTP──►  Next request handler                          ┐
browser ──HTTP──►  /mcp StreamableHTTPServerTransport            │── server.ts (one Node process)
browser ──WS────►  /ws/terminal → attachPty                      │
browser ──WS────►  /ws/canvas   → attachCanvas                   ┘
                                ↓                       ↓                   ↓
                          node-pty.spawn($SHELL)    scene cache         McpServer + tools
                          cwd: WORKSPACE_DIR        (canvasBridge)      (read/write cache,
                          auto-runs `claude`                             broadcast to /ws/canvas)
```

- **Custom server** ([server.ts](server.ts)): hosts Next, two `WebSocketServer({ noServer: true })` (terminal + canvas), and the MCP transport. The `'upgrade'` listener routes `/ws/terminal` and `/ws/canvas`; everything else (HMR, etc.) is forwarded to `app.getUpgradeHandler()`. `mountMcp()` shims the `'request'` listener so `/mcp` goes to the MCP transport before falling through to Next. Both `getRequestHandler()` and `getUpgradeHandler()` **must be called inside `app.prepare().then(...)`**, never at module top level — they throw "prepare() must be called" otherwise.

- **PTY bridge** ([src/server/pty.ts](src/server/pty.ts)): one `node-pty` process per WS connection. Spawns the user's `$SHELL` with `cwd: WORKSPACE_DIR` and writes `claude --dangerously-skip-permissions\r` immediately so the page lands in a Claude session. Wire protocol:
  - server → client: **binary** frames = raw pty bytes
  - client → server, **binary**: raw keystrokes → `pty.write`
  - client → server, **text** (JSON): control messages, currently `{type:"resize", cols, rows}`

  Keep new control messages on the text channel; never multiplex into the binary stream.

- **Canvas WS bridge** ([src/server/canvasBridge.ts](src/server/canvasBridge.ts) ↔ [src/lib/canvasBus.ts](src/lib/canvasBus.ts) ↔ [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx)): duplex sync between the browser's Excalidraw canvas and the server-side scene cache. Text-only JSON, single channel:
  - browser → server: `{type:"snapshot", elements, appState, files}` on connect and on every 500ms debounce of `onChange`. Server replaces its cache.
  - server → browser: `{type:"set", elements, appState, files}` (full replace) and `{type:"patch", mode:"append", elements}` (incremental). Browser applies via `excalidrawAPI.updateScene({ ..., captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so `Cmd+Z` undoes server-driven writes.

  Last-writer-wins. No CRDT. `canvasBridge` holds the authoritative cache **server-side**; MCP tools read/write it directly without IPC.

- **MCP server** ([src/server/mcp.ts](src/server/mcp.ts)): in-process `McpServer` + `StreamableHTTPServerTransport` (SDK v1) at `/mcp`. Tools: `get_canvas_state`, `set_canvas_state`, `add_elements`, `clear_canvas` — all delegate to `canvasBridge`, broadcasting any mutation to connected browsers via `/ws/canvas`. Per-session map keyed by `mcp-session-id` header; localhost-only DNS rebinding protection. **Mounted on the bare `http.createServer`, not under `app/api/.../route.ts`** — the SDK transport wants Node `IncomingMessage`/`ServerResponse`, not Web Fetch types. Don't import `@excalidraw/excalidraw` in `mcp.ts` or `canvasBridge.ts` — it touches `window` at module load.

- **terminalBus** ([src/lib/terminalBus.ts](src/lib/terminalBus.ts)): in-browser pubsub seam between the left panel and the Terminal component. Public: `sendToTerminal(text)`, `onTerminalOutput(cb) → unsubscribe`. The `_onSend` / `_emitOutput` underscore methods are wired by `Terminal.tsx` only — do not call from feature code. In dev exposed at `window.__tangoBus`.

- **canvasBus** ([src/lib/canvasBus.ts](src/lib/canvasBus.ts)): sibling of `terminalBus`. SketchPanel owns the WS to `/ws/canvas` and forwards through this bus: server frames → DesignerCanvas (`_onApply`); local debounced snapshots → SketchPanel WS sender (`_onSnapshot`). Public surface is the underscore methods plus `_emitApply`/`_emitSnapshot` — feature code should not need to touch any of it. In dev exposed at `window.__tangoCanvasBus`.

- **Terminal component** ([src/components/Terminal.tsx](src/components/Terminal.tsx)): must stay client-only. Imported via `dynamic(() => import('@/components/Terminal'), { ssr: false })` in [src/app/page.tsx](src/app/page.tsx). xterm.js touches the DOM and explodes on SSR. Resize is a debounced `ResizeObserver` (50ms) that calls `fitAddon.fit()` then sends a JSON resize.

- **Designer mode** ([src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) + [src/components/DesignerCanvas.tsx](src/components/DesignerCanvas.tsx)): the left pane is an Excalidraw canvas. `SketchPanel` is the SSR-safe shell that owns the `/ws/canvas` socket; `DesignerCanvas` is the dynamic-import boundary that pulls in `@excalidraw/excalidraw` (it touches `window` at module load — same SSR pattern as `Terminal`). `DesignerCanvas` captures the imperative API into a ref it owns, exposing `applyScene` / `appendElements` upward via `DesignerHandles`; both call `updateScene({ captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so server writes are undoable. `sketchStore` ([src/lib/sketchStore.ts](src/lib/sketchStore.ts)) is the browser's localStorage-backed cache — it survives refresh; the server cache in `canvasBridge` is the cross-process source of truth. "Send to Claude" still exports a PNG, POSTs it to [`/api/design/snapshot`](src/app/api/design/snapshot/route.ts) which writes `${WORKSPACE_DIR}/design-scratch/<iso-ts>-<rand>.png`, then types `# review design at design-scratch/...png\n` into the terminal via `terminalBus.sendToTerminal`. The leading `#` is load-bearing — bash/zsh would auto-execute a bare path on the next Return — and the relative path resolves because Claude's cwd is `WORKSPACE_DIR`.

## Workspace

`WORKSPACE_DIR` ([src/server/workspace.ts](src/server/workspace.ts)) defaults to `~/dev/tangotest`; override with `TANGO_WORKSPACE`. Three things land there:

- **`.mcp.json`** — generated config; **overwritten** on every server boot to point at `http://localhost:<PORT>/mcp`. Hand-edits will not survive.
- **`.claude/settings.json`** — **merged** on every server boot. We add `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and preserve any other keys (hooks, theme, model, …).
- **`design-scratch/`** — PNGs from "Send to Claude" land here.

The PTY's `cwd` and the snapshot route both read `WORKSPACE_DIR`, so all the file-paths Claude is told about resolve from its own cwd.

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

- **MCP tools are the seam for AI canvas writes.** Don't reach into `canvasBridge` from outside [server.ts](server.ts) / [src/server/mcp.ts](src/server/mcp.ts). New AI capabilities go on as new tools in `mcp.ts` so claude-code (and any future agent) gets them automatically.
- **Don't bypass `terminalBus` or `canvasBus`** by reaching into the WebSockets from outside `Terminal.tsx` / `SketchPanel.tsx`. Buses are the seams; future features (recording, multi-tab, alternate transports) will hook them.
- **Don't import `@excalidraw/excalidraw` outside [DesignerCanvas.tsx](src/components/DesignerCanvas.tsx).** Excalidraw initializes against `window` at module load and dies on SSR — and on the server. The dynamic-import boundary lives in `SketchPanel` (`dynamic(() => import('./DesignerCanvas'), { ssr: false })`); other code reaches the canvas through [sketchStore](src/lib/sketchStore.ts), the `DesignerHandles` callback, or the `canvasBus`, never by touching the package directly. The server constructs Excalidraw scene JSON by hand instead.
- **Sanitize `appState` at every JSON boundary** via [`sanitizeAppState`](src/lib/canvasBus.ts). Excalidraw's appState contains `Map`/`Set` fields (`collaborators`, `pointers`, `followedBy`) that JSON.stringify silently flattens to `{}`; if that round-trips back into the canvas, Excalidraw crashes on `.forEach`. Anywhere we serialize, store, or transit appState, run it through the sanitizer.
- **Bridge to the terminal via comment lines, not bare paths.** `terminalBus.sendToTerminal` writes whatever you hand it directly into the PTY. A bare path gets executed on the next Return; prefix with `#` so it parks in scrollback as an editable prompt seed.
- **`design-scratch/` is workspace scratch.** Lives at `${WORKSPACE_DIR}/design-scratch/`, gitignored. Resolved via [src/server/workspace.ts](src/server/workspace.ts) — never hardcode the path elsewhere. Electron will swap the path for `app.getPath('userData')` in one place.
- **Workspace files `.mcp.json` and `.claude/settings.json` are managed.** `ensureWorkspace()` overwrites `.mcp.json` and merges `.claude/settings.json` on every server boot. Add new managed keys to [src/server/workspace.ts](src/server/workspace.ts), not by hand-editing the workspace.
- **No `next dev`, no Vercel adapters, no edge runtime.** Custom Node server is load-bearing because the WSes and the MCP transport live in-process, and Electron will swap them for IPC against the same `attachPty` / `attachCanvas` / `mountMcp` surfaces.
- **Strict Mode is on.** Terminal effect runs twice in dev → one harmless "WebSocket is closed before the connection is established" warning per mount, plus `claude` boots twice on first load (the first PTY is killed by the Strict-Mode cleanup). Don't "fix" by disabling Strict Mode.

## Vision (so future changes don't paint into a corner)

1. **Now:** terminal auto-launches `claude --dangerously-skip-permissions` in `WORKSPACE_DIR`. MCP server gives it `get_canvas_state` / `set_canvas_state` / `add_elements` / `clear_canvas`. Designer mode is duplex — Claude writes via MCP, user edits flow back to the server cache via the same WS bridge. PNG-on-disk + comment-line ping is still around as a vision channel.
2. **Next:** richer canvas tools (image insertion, select-and-modify by element ID, scoped diffs). Other agents (codex). Per-tab / per-project workspaces. Possibly recording the bus traffic for replay.
3. **Later:** package as Electron. The renderer drops the WSes and calls `attachPty` / `attachCanvas` / `mountMcp` equivalents over IPC; [designSnapshot.ts](src/lib/designSnapshot.ts) swaps its POST for direct `fs.writeFile` against `app.getPath('userData')`. The rest of the React tree is unchanged.

## Files that matter

- [server.ts](server.ts) — Next + WS upgrade routing + MCP mount
- [src/server/pty.ts](src/server/pty.ts) — node-pty ↔ WS bridge; auto-launches `claude` in `WORKSPACE_DIR`
- [src/server/canvasBridge.ts](src/server/canvasBridge.ts) — server-side scene cache + `/ws/canvas` hub
- [src/server/mcp.ts](src/server/mcp.ts) — `McpServer` + Streamable HTTP transport at `/mcp`; tool registrations
- [src/server/workspace.ts](src/server/workspace.ts) — `WORKSPACE_DIR` + `ensureWorkspace()` (managed `.mcp.json` / `.claude/settings.json`)
- [src/components/Terminal.tsx](src/components/Terminal.tsx) — xterm + FitAddon + WS + bus wiring
- [src/lib/terminalBus.ts](src/lib/terminalBus.ts) — in-app pubsub seam (terminal)
- [src/lib/canvasBus.ts](src/lib/canvasBus.ts) — in-app pubsub seam (canvas) + `sanitizeAppState`
- [src/app/page.tsx](src/app/page.tsx) — split-pane layout
- [src/components/LeftPanel.tsx](src/components/LeftPanel.tsx) — one-line shell that mounts `<SketchPanel />`
- [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) — SSR-safe parent: toolbar, "Send to Claude", `/ws/canvas` socket, dynamic-imports the canvas
- [src/components/DesignerCanvas.tsx](src/components/DesignerCanvas.tsx) — Excalidraw wrapper; the only file that imports `@excalidraw/excalidraw`. Owns the imperative API ref; exposes `applyScene` / `appendElements`.
- [src/lib/sketchStore.ts](src/lib/sketchStore.ts) — plain-module canvas state (localStorage-backed; mirrors server cache for refresh-survival)
- [src/lib/designSnapshot.ts](src/lib/designSnapshot.ts) — write-snapshot adapter (web POSTs; Electron will swap to `fs.writeFile`)
- [src/app/api/design/snapshot/route.ts](src/app/api/design/snapshot/route.ts) — POST handler that writes PNGs to `${WORKSPACE_DIR}/design-scratch/`
- [scripts/fix-node-pty.js](scripts/fix-node-pty.js) — postinstall workaround
