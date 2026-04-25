@AGENTS.md

# tango

Split-pane web app: arbitrary content on the left, an interactive xterm.js terminal on the right backed by a real shell via `node-pty`. Designed to grow into a host for codex / claude-code agents that act on the left panel.

Stack: **Next.js 16 (App Router) + React 19 + Tailwind v4**, custom Node server, WebSocket bridge to `node-pty`, Excalidraw on the left for designer mode, in-process MCP server giving Claude tools to drive the canvas, plus a **gpt-5.5 "controller agent"** (Vercel AI SDK v6 + `@ai-sdk/mcp`) that drives the visible UI cursor and delegates intelligence to the terminal-Claude session. Will eventually be packaged as an Electron app — keep that path open (no Vercel-only assumptions, no edge runtime).

The repo and the workspace Claude operates in are **separate directories** by design. This repo is for tango itself; Claude lands in `~/dev/tangotest` (override via `TANGO_WORKSPACE`). See **Workspace** below.

## Run / build

```
npm run dev      # tsx server.ts on :3000
npm run build    # next build (server stays the same)
npm start        # production server
```

The dev script runs the **custom server**, not `next dev`. Do not change to `next dev` — it will break the WebSocket bridge.

On boot the server provisions the workspace dir (creates `~/dev/tangotest`, writes `.mcp.json` and `CLAUDE.md`, merges `.claude/settings.json`, ensures `design-scratch/`). Wipe the dir and the next `npm run dev` recreates it.

## Architecture (non-obvious bits)

```
browser ──HTTP──►  Next request handler                                 ┐
browser ──HTTP──►  /mcp        StreamableHTTPServerTransport            │
browser ──HTTP──►  /api/agent  streamText + @ai-sdk/mcp client          │── server.ts (one Node process)
browser ──WS────►  /ws/terminal      → attachPty                        │
browser ──WS────►  /ws/canvas        → attachCanvas                     │
browser ──WS────►  /ws/agent-cursor  → attachAgentCursor                ┘
                                ↓                       ↓                   ↓
                          node-pty.spawn($SHELL)    scene cache         McpServer + tools
                          cwd: WORKSPACE_DIR        (canvasBridge)      (canvas + agent UI tools,
                          auto-runs `claude`                             broadcast to /ws/canvas
                                                                          and /ws/agent-cursor)
```

- **Custom server** ([server.ts](server.ts)): hosts Next, three `WebSocketServer({ noServer: true })` (terminal + canvas + agent-cursor), and the MCP transport. The `'upgrade'` listener routes `/ws/terminal`, `/ws/canvas`, and `/ws/agent-cursor`; everything else (HMR, etc.) is forwarded to `app.getUpgradeHandler()`. `mountMcp()` shims the `'request'` listener so `/mcp` goes to the MCP transport before falling through to Next. Both `getRequestHandler()` and `getUpgradeHandler()` **must be called inside `app.prepare().then(...)`**, never at module top level — they throw "prepare() must be called" otherwise.

- **PTY bridge** ([src/server/pty.ts](src/server/pty.ts)): one `node-pty` process per WS connection. Spawns the user's `$SHELL` with `cwd: WORKSPACE_DIR` and writes `claude --dangerously-skip-permissions\r` immediately so the page lands in a Claude session. Wire protocol:
  - server → client: **binary** frames = raw pty bytes
  - client → server, **binary**: raw keystrokes → `pty.write`
  - client → server, **text** (JSON): control messages, currently `{type:"resize", cols, rows}`

  Keep new control messages on the text channel; never multiplex into the binary stream.

- **Canvas WS bridge** ([src/server/canvasBridge.ts](src/server/canvasBridge.ts) ↔ [src/lib/canvasBus.ts](src/lib/canvasBus.ts) ↔ [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx)): duplex sync between the browser's Excalidraw canvas and the server-side scene cache. Text-only JSON, single channel:
  - browser → server: `{type:"snapshot", elements, appState, files}` on connect and on every 500ms debounce of `onChange`. Server replaces its cache.
  - server → browser: `{type:"set", elements, appState, files}` (full replace) and `{type:"patch", mode:"append", elements}` (incremental). Browser applies via `excalidrawAPI.updateScene({ ..., captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so `Cmd+Z` undoes server-driven writes.

  Last-writer-wins. No CRDT. `canvasBridge` holds the authoritative cache **server-side**; MCP tools read/write it directly without IPC.

- **MCP server** ([src/server/mcp.ts](src/server/mcp.ts)): in-process `McpServer` + `StreamableHTTPServerTransport` (SDK v1) at `/mcp`. Two tool groups, all in one server:
  - *Canvas tools* — `get_canvas_state`, `set_canvas_state`, `add_elements`, `clear_canvas`, `screenshot_canvas`. Delegate to `canvasBridge`, broadcast mutations to browsers via `/ws/canvas`. `screenshot_canvas` is a round-trip caller — it sends `{type:'screenshot_request',requestId,…}` over `/ws/canvas` and awaits `{type:'screenshot_result',requestId,mime,data}` from SketchPanel (which calls `DesignerHandles.getImage`). Mirrors the `dom_inspect` pattern but on the canvas WS instead of the agent-cursor WS, because only DesignerCanvas can render Excalidraw.
  - *Agent UI tools* — `dom_inspect`, `cursor_move`, `cursor_click`, `cursor_type`, `terminal_type`. Push commands over `/ws/agent-cursor` to the browser overlay (cursor moves/clicks/typing) or into `terminalBus` (terminal_type). `dom_inspect` is the one round-trip caller — it sends `{type:'inspect',requestId,…}` and awaits a matching `{type:'inspect_result',requestId,result}` reply.

  Per-session map keyed by `mcp-session-id` header; localhost-only DNS rebinding protection. **Mounted on the bare `http.createServer`, not under `app/api/.../route.ts`** — the SDK transport wants Node `IncomingMessage`/`ServerResponse`, not Web Fetch types. Don't import `@excalidraw/excalidraw` in `mcp.ts` or `canvasBridge.ts` — it touches `window` at module load. **`transport.onclose` must NOT call `mcpServer.close()`** — `server.close()` calls `transport.close()`, which fires `onclose` again → infinite recursion. Just drop the session-map entry; the server is GC'd once unreferenced.

- **terminalBus** ([src/lib/terminalBus.ts](src/lib/terminalBus.ts)): in-browser pubsub seam between the left panel and the Terminal component. Public: `sendToTerminal(text)`, `onTerminalOutput(cb) → unsubscribe`. The `_onSend` / `_emitOutput` underscore methods are wired by `Terminal.tsx` only — do not call from feature code. In dev exposed at `window.__tangoBus`.

- **canvasBus** ([src/lib/canvasBus.ts](src/lib/canvasBus.ts)): sibling of `terminalBus`. SketchPanel owns the WS to `/ws/canvas` and forwards through this bus: server frames → DesignerCanvas (`_onApply`); local debounced snapshots → SketchPanel WS sender (`_onSnapshot`). Public surface is the underscore methods plus `_emitApply`/`_emitSnapshot` — feature code should not need to touch any of it. In dev exposed at `window.__tangoCanvasBus`.

- **Terminal component** ([src/components/Terminal.tsx](src/components/Terminal.tsx)): must stay client-only. Imported via `dynamic(() => import('@/components/Terminal'), { ssr: false })` in [src/app/page.tsx](src/app/page.tsx). xterm.js touches the DOM and explodes on SSR. Resize is a debounced `ResizeObserver` (50ms) that calls `fitAddon.fit()` then sends a JSON resize.

- **Designer mode** ([src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) + [src/components/DesignerCanvas.tsx](src/components/DesignerCanvas.tsx)): the left pane is an Excalidraw canvas. `SketchPanel` is the SSR-safe shell that owns the `/ws/canvas` socket; `DesignerCanvas` is the dynamic-import boundary that pulls in `@excalidraw/excalidraw` (it touches `window` at module load — same SSR pattern as `Terminal`). `DesignerCanvas` captures the imperative API into a ref it owns, exposing `applyScene` / `appendElements` upward via `DesignerHandles`; both call `updateScene({ captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so server writes are undoable. `sketchStore` ([src/lib/sketchStore.ts](src/lib/sketchStore.ts)) is the browser's localStorage-backed cache — it survives refresh; the server cache in `canvasBridge` is the cross-process source of truth. "Send to Claude" still exports a PNG, POSTs it to [`/api/design/snapshot`](src/app/api/design/snapshot/route.ts) which writes `${WORKSPACE_DIR}/design-scratch/<iso-ts>-<rand>.png`, then types `# review design at design-scratch/...png\n` into the terminal via `terminalBus.sendToTerminal`. The leading `#` is load-bearing — bash/zsh would auto-execute a bare path on the next Return — and the relative path resolves because Claude's cwd is `WORKSPACE_DIR`.

- **Controller agent** ([src/app/api/agent/route.ts](src/app/api/agent/route.ts) + [src/components/AgentTrigger.tsx](src/components/AgentTrigger.tsx) + [src/components/AgentCursorOverlay.tsx](src/components/AgentCursorOverlay.tsx) + [src/server/agentCursorBridge.ts](src/server/agentCursorBridge.ts)): a small "Tell the agent what to do…" input lives in the SketchPanel toolbar. Submitting POSTs to `/api/agent`, which spins up a Vercel AI SDK `streamText` loop against `gpt-5.5` (model + key in [src/lib/ai.ts](src/lib/ai.ts), `reasoningEffort: 'low'`), connects an `@ai-sdk/mcp` HTTP client to *this same* `/mcp` endpoint, and exposes a **filtered** subset of tools to the model. The browser side is `AgentTrigger` (uses `useChat` from `@ai-sdk/react`) for the goal box + log panel, and `AgentCursorOverlay` for the visible cursor sprite + DOM event dispatch + terminal-write seam. Load-bearing details:

  - **Tool allowlist.** `/api/agent` filters `await client.tools()` through `ALLOWED_TOOLS` to expose only `dom_inspect`, `cursor_move`, `cursor_click`, `cursor_type`, `terminal_type`. The four canvas tools are explicitly hidden — gpt-5.5 is a *controller*, not the brain. If we let it see the canvas tools it short-circuits and draws things itself instead of delegating to terminal-Claude. If you add a new tool to `mcp.ts` and want the agent to use it, add its name to `ALLOWED_TOOLS`.
  - **Same-origin MCP.** The route builds the MCP URL from `req.url` (`${url.protocol}//${url.host}/mcp`). Don't hardcode `http://localhost:3000/mcp` — Electron loopback and proxied dev URLs both depend on this.
  - **`/ws/agent-cursor` is bidirectional.** Server → browser carries `move`/`click`/`type`/`terminal_type`/`inspect` commands; browser → server carries `inspect_result` replies (and only that, today). New round-trip tools should reuse the `requestId` correlation pattern in [agentCursorBridge.ts](src/server/agentCursorBridge.ts).
  - **`terminal_type` defaults to `submit:true` and writes the text and the `\r` as two separate PTY writes** (~120ms gap). Single-fused chunks were sometimes treated as a paste by Claude Code's TUI and the trailing `\r` didn't fire the Enter handler. Don't collapse the writes back into one.
  - **`dom_inspect` is the right way to find UI targets.** Agent prompts and tool descriptions both push the model to call it before any `cursor_move`/`cursor_click`. Returns interactive elements with role, accessible name, visible text, pixel rect, and `center: {x,y}` — the model passes that center straight to `cursor_click({x,y})` instead of guessing selectors. If you build new agent capabilities, prefer extending `dom_inspect` over teaching the model selector grammar.
  - **`AgentCursorOverlay` is mounted once in [layout.tsx](src/app/layout.tsx)** so the cursor is available on every route. The sprite is `position: fixed`, `pointerEvents: 'none'`, `z-index: 99999`, and tagged `data-agent-cursor` so it can be filtered out of `dom_inspect` results in the future if needed.

## Workspace

`WORKSPACE_DIR` ([src/server/workspace.ts](src/server/workspace.ts)) defaults to `~/dev/tangotest`; override with `TANGO_WORKSPACE`. Four things land there:

- **`.mcp.json`** — generated config; **overwritten** on every server boot to point at `http://localhost:<PORT>/mcp`. Hand-edits will not survive.
- **`CLAUDE.md`** — generated docs telling Claude about the `tango-canvas` MCP tools; **overwritten** on every server boot. Hand-edits will not survive.
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

- **MCP tools are the seam for AI capabilities.** Don't reach into `canvasBridge` or `agentCursorBridge` from outside [server.ts](server.ts) / [src/server/mcp.ts](src/server/mcp.ts). New AI capabilities go on as new MCP tools so terminal-Claude gets them automatically. To expose a new tool to the **controller agent** as well, add its name to the `ALLOWED_TOOLS` set in [src/app/api/agent/route.ts](src/app/api/agent/route.ts) — by default it sees nothing new.
- **The controller agent is a controller, not the brain.** [src/app/api/agent/route.ts](src/app/api/agent/route.ts) exists to (1) translate user goals into prompts for terminal-Claude via `terminal_type`, and (2) move the visible cursor so the human can see what's happening. Anything creative — design, code, copy, brainstorming, "come up with X" — is delegated. The hard rules and standard playbook live in `SYSTEM_PROMPT` in that file. If you change the agent's behavior, change them there; do not loosen the toolset to give it shortcuts.
- **Don't bypass `terminalBus`, `canvasBus`, or `agentCursorBridge`** by reaching into the WebSockets from outside `Terminal.tsx` / `SketchPanel.tsx` / `AgentCursorOverlay.tsx`. Buses are the seams; future features (recording, multi-tab, alternate transports) will hook them.
- **Don't import `@excalidraw/excalidraw` outside [DesignerCanvas.tsx](src/components/DesignerCanvas.tsx).** Excalidraw initializes against `window` at module load and dies on SSR — and on the server. The dynamic-import boundary lives in `SketchPanel` (`dynamic(() => import('./DesignerCanvas'), { ssr: false })`); other code reaches the canvas through [sketchStore](src/lib/sketchStore.ts), the `DesignerHandles` callback, or the `canvasBus`, never by touching the package directly. The server constructs Excalidraw scene JSON by hand instead.
- **Sanitize `appState` at every JSON boundary** via [`sanitizeAppState`](src/lib/canvasBus.ts). Excalidraw's appState contains `Map`/`Set` fields (`collaborators`, `pointers`, `followedBy`) that JSON.stringify silently flattens to `{}`; if that round-trips back into the canvas, Excalidraw crashes on `.forEach`. Anywhere we serialize, store, or transit appState, run it through the sanitizer.
- **Bridge to the terminal via comment lines, not bare paths.** `terminalBus.sendToTerminal` writes whatever you hand it directly into the PTY. A bare path gets executed on the next Return; prefix with `#` so it parks in scrollback as an editable prompt seed. (The agent's `terminal_type` MCP tool is the exception — it's *meant* to submit; it sends text and `\r` as two writes so Claude Code's TUI sees the Enter as a real keystroke, not part of a paste.)
- **`dom_inspect` before `cursor_click`.** Hand-rolled CSS selectors miss; the model has no view of the page. The system prompt enforces this for the controller agent; if you add new agent flows or new UI controls that the agent should reach, expose accessible names (`aria-label`, visible text on `<button>`s) so `dom_inspect` can find them by `query` string.
- **`design-scratch/` is workspace scratch.** Lives at `${WORKSPACE_DIR}/design-scratch/`, gitignored. Resolved via [src/server/workspace.ts](src/server/workspace.ts) — never hardcode the path elsewhere. Electron will swap the path for `app.getPath('userData')` in one place.
- **Workspace files `.mcp.json`, `CLAUDE.md`, and `.claude/settings.json` are managed.** `ensureWorkspace()` overwrites `.mcp.json` and `CLAUDE.md` and merges `.claude/settings.json` on every server boot. Add new managed keys to [src/server/workspace.ts](src/server/workspace.ts), not by hand-editing the workspace.
- **No `next dev`, no Vercel adapters, no edge runtime.** Custom Node server is load-bearing because the WSes and the MCP transport live in-process, and Electron will swap them for IPC against the same `attachPty` / `attachCanvas` / `mountMcp` surfaces.
- **Strict Mode is on.** Terminal effect runs twice in dev → one harmless "WebSocket is closed before the connection is established" warning per mount, plus `claude` boots twice on first load (the first PTY is killed by the Strict-Mode cleanup). Don't "fix" by disabling Strict Mode.

## Vision (so future changes don't paint into a corner)

1. **Now:** terminal auto-launches `claude --dangerously-skip-permissions` in `WORKSPACE_DIR`. MCP server gives it canvas tools (read/write the scene) and agent UI tools (`dom_inspect` + cursor + `terminal_type`). A small gpt-5.5 controller agent in the toolbar takes user goals, finds UI targets via `dom_inspect`, moves the visible cursor, and delegates the actual brainwork to terminal-Claude via `terminal_type`. Designer mode is duplex. PNG-on-disk + comment-line ping is still around as a manual vision channel.
2. **Next:** richer canvas tools (image insertion, select-and-modify by element ID, scoped diffs). A `screenshot_canvas` tool that returns rendered pixels so terminal-Claude can *see* the sketch (not just parse element JSON). Tool-call verification (e.g. `cursor_click` returns "landed on `<button>X</button>`" so the model self-corrects). Other agents (codex). Per-tab / per-project workspaces. Possibly recording the bus traffic for replay.
3. **Later:** package as Electron. The renderer drops the WSes and calls `attachPty` / `attachCanvas` / `attachAgentCursor` / `mountMcp` equivalents over IPC; [designSnapshot.ts](src/lib/designSnapshot.ts) swaps its POST for direct `fs.writeFile` against `app.getPath('userData')`. The rest of the React tree is unchanged.

## Files that matter

- [server.ts](server.ts) — Next + WS upgrade routing + MCP mount
- [src/server/pty.ts](src/server/pty.ts) — node-pty ↔ WS bridge; auto-launches `claude` in `WORKSPACE_DIR`
- [src/server/canvasBridge.ts](src/server/canvasBridge.ts) — server-side scene cache + `/ws/canvas` hub
- [src/server/mcp.ts](src/server/mcp.ts) — `McpServer` + Streamable HTTP transport at `/mcp`; tool registrations
- [src/server/workspace.ts](src/server/workspace.ts) — `WORKSPACE_DIR` + `ensureWorkspace()` (managed `.mcp.json` / `CLAUDE.md` / `.claude/settings.json`)
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
- [src/app/api/agent/route.ts](src/app/api/agent/route.ts) — controller agent route: `streamText` + `@ai-sdk/mcp` client + `ALLOWED_TOOLS` filter + `SYSTEM_PROMPT`
- [src/lib/ai.ts](src/lib/ai.ts) — `openai` provider re-export + `VISION_MODEL` (`gpt-5.5`) + `IMAGE_MODEL`
- [src/server/agentCursorBridge.ts](src/server/agentCursorBridge.ts) — server-side `/ws/agent-cursor` hub: `pushCursorCommand` (fire-and-forget) + `requestInspect` (round-trip with `requestId`)
- [src/components/AgentCursorOverlay.tsx](src/components/AgentCursorOverlay.tsx) — visible cursor sprite, DOM-event dispatcher, terminal-write seam, DOM walker for `dom_inspect`. Mounted once in [src/app/layout.tsx](src/app/layout.tsx)
- [src/components/AgentTrigger.tsx](src/components/AgentTrigger.tsx) — toolbar input + Run button + log panel; uses `useChat` from `@ai-sdk/react` against `/api/agent`
- [scripts/fix-node-pty.js](scripts/fix-node-pty.js) — postinstall workaround
