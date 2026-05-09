@AGENTS.md

# tango

Split-pane web app: an Excalidraw / UI-mock / moodboard canvas on the left, a custom AI chat harness on the right. The chat is the brain — it reads and mutates the canvas through an in-process MCP server and routes work between models (Anthropic for orchestration / code, Google for vision, OpenAI for memory summarization).

Stack: **Next.js 16 (App Router) + React 19 + Tailwind v4**, custom Node server, in-process MCP server (`@modelcontextprotocol/sdk`), and a Vercel-AI-SDK chat harness (`ai@^6` + `@ai-sdk/react` + provider packages for OpenAI / Anthropic / Google + `@ai-sdk/mcp`). Will eventually be packaged as an Electron app — keep that path open (no Vercel-only assumptions, no edge runtime).

The repo and the workspace tango operates on are **separate directories** by design. This repo is for tango itself; the workspace is whatever folder the user picks in the in-app picker (or the path pinned by `TANGO_WORKSPACE`). See **Workspace** below.

## Run / build

```
npm run dev      # tsx server.ts on :3000
npm run build    # next build (server stays the same)
npm start        # production server
npm test         # vitest run
npm run test:watch
```

Provider keys are read from the environment by the AI SDK provider packages: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`. `safeModel()` in [src/lib/ai.ts](src/lib/ai.ts) falls through Anthropic → OpenAI → Google when a preferred key is missing, logging once.

The dev script runs the **custom server**, not `next dev`. Do not change to `next dev` — it will break the WebSocket bridges and the MCP transport.

On boot the server resolves the active workspace (env var → persisted `~/.tango/state.json` → null). When a workspace is set, it's ensured non-destructively: `.claude/tango.md` (overwrite), `CLAUDE.md` (sentinel block only — preserves user content byte-for-byte outside the block), `.mcp.json` (merge under `mcpServers['tango-canvas']` — refuses on malformed JSON), `.claude/settings.json` (merge `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), and `design-scratch/`. **These files are written so users can also point the standalone `claude` CLI at the same workspace** — tango's chat doesn't depend on them. If no workspace is set, the browser shows a blocking picker and `/api/design/snapshot` returns 409 until one is chosen.

## Architecture (non-obvious bits)

```
browser ──HTTP──►  Next request handler                               ┐
browser ──HTTP──►  /mcp        StreamableHTTPServerTransport          │
browser ──HTTP──►  /api/chat   streamText + @ai-sdk/mcp client        │── server.ts (one Node process)
browser ──HTTP──►  /api/sim/status  → getSimStatus()                  │
browser ──WS────►  /ws/canvas       → attachCanvas                    │
browser ──WS────►  /ws/ui-mock      → attachUIMock                    ┘
                            ↓                                ↓
                      scene cache                     McpServer + tools
                      (canvasBridge,                  (canvas, ui-mock,
                       uiMockBridge)                   ios, memory),
                                                      broadcast to
                                                      /ws/canvas + /ws/ui-mock
```

On darwin, server boot also calls `startSimHelper()` once — see the **Simulator panel** subsection below for the spawn / iframe path that doesn't fit cleanly in the request-routing diagram.

- **Custom server** ([server.ts](server.ts)): hosts Next, two `WebSocketServer({ noServer: true })` (canvas + ui-mock), and the MCP transport. The `'upgrade'` listener routes `/ws/canvas` and `/ws/ui-mock`; everything else (HMR, etc.) is forwarded to `app.getUpgradeHandler()`. `mountMcp()` shims the `'request'` listener so `/mcp` goes to the MCP transport before falling through to Next. Both `getRequestHandler()` and `getUpgradeHandler()` **must be called inside `app.prepare().then(...)`**, never at module top level — they throw "prepare() must be called" otherwise.

- **Canvas WS bridge** ([src/server/canvasBridge.ts](src/server/canvasBridge.ts) ↔ [src/lib/canvasBus.ts](src/lib/canvasBus.ts) ↔ [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx)): duplex sync between the browser's Excalidraw canvas and the server-side scene cache. Text-only JSON, single channel:
  - browser → server: `{type:"snapshot", elements, appState, files}` on connect and on every 500ms debounce of `onChange`. Server replaces its cache.
  - server → browser: `{type:"set", elements, appState, files}` (full replace) and `{type:"patch", mode:"append", elements}` (incremental). Browser applies via `excalidrawAPI.updateScene({ ..., captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so `Cmd+Z` undoes server-driven writes.

  Last-writer-wins. No CRDT. `canvasBridge` holds the authoritative cache **server-side**; MCP tools read/write it directly without IPC.

- **MCP server** ([src/server/mcp.ts](src/server/mcp.ts)): in-process `McpServer` + `StreamableHTTPServerTransport` (SDK v1) at `/mcp`. Four tool groups, all in one server:
  - *Canvas tools* — `get_canvas_state`, `set_canvas_state`, `add_elements`, `clear_canvas`, `screenshot_canvas`, `set_screen_flow`. Delegate to `canvasBridge`, broadcast mutations to browsers via `/ws/canvas`. `screenshot_canvas` is a round-trip caller — it sends `{type:'screenshot_request',requestId,…}` over `/ws/canvas` and awaits `{type:'screenshot_result',requestId,mime,data}` from SketchPanel (which calls `DesignerHandles.getImage`), because only DesignerCanvas can render Excalidraw.
  - *UI-mock tools* — `get_ui_mock`, `get_ui_viewport`, `set_ui_mock`, `add_ui_screen`, `clear_ui_mock`. Same pattern as the canvas tools but against `uiMockBridge` and `/ws/ui-mock`.
  - *iOS tools* — `ios_status`, `ios_build_run`, `ios_logs_recent`. Drive `xcodebuild`/`simctl` in the workspace. `ios_status` returns `project.kind: 'none'` if no Xcode project is detected; the chat brain bails gracefully in that case.
  - *Memory tool* — `remember_note` appends a categorized note to `<workspace>/tango-memory.md`. The same memory file logs every chat turn's outcome via `appendEvent({type:'agent_run', …})` from [src/app/api/chat/route.ts](src/app/api/chat/route.ts).

  Per-session map keyed by `mcp-session-id` header; localhost-only DNS rebinding protection. **Mounted on the bare `http.createServer`, not under `app/api/.../route.ts`** — the SDK transport wants Node `IncomingMessage`/`ServerResponse`, not Web Fetch types. Don't import `@excalidraw/excalidraw` in `mcp.ts` or `canvasBridge.ts` — it touches `window` at module load. **`transport.onclose` must NOT call `mcpServer.close()`** — `server.close()` calls `transport.close()`, which fires `onclose` again → infinite recursion. Just drop the session-map entry; the server is GC'd once unreferenced.

- **canvasBus / uiMockBus / chatBus** ([src/lib/canvasBus.ts](src/lib/canvasBus.ts), [src/lib/uiMockBus.ts](src/lib/uiMockBus.ts), [src/lib/chatBus.ts](src/lib/chatBus.ts)): in-browser pubsub seams. `canvasBus` and `uiMockBus` carry duplex traffic between the WS-owning panel (SketchPanel / UIPanel) and the canvas/mock dynamic-import boundary. `chatBus` is one-way — feature panels (SketchPanel "Send to chat", UIPanel handoff, MoodboardPanel handoff) call `chatBus.send(text)` and ChatPanel forwards the text to its `useChat` `sendMessage`. Public surface stays narrow; the underscore methods (`_onSend`, `_emitApply`, `_emitSnapshot`) are wired by the panel that owns the bus, never by feature code. In dev exposed at `window.__tangoChatBus`, `window.__tangoCanvasBus`.

- **Designer mode** ([src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) + [src/components/DesignerCanvas.tsx](src/components/DesignerCanvas.tsx)): the left pane is an Excalidraw canvas. `SketchPanel` is the SSR-safe shell that owns the `/ws/canvas` socket; `DesignerCanvas` is the dynamic-import boundary that pulls in `@excalidraw/excalidraw` (it touches `window` at module load — keep it behind `dynamic({ ssr: false })`). `DesignerCanvas` captures the imperative API into a ref it owns, exposing `applyScene` / `appendElements` upward via `DesignerHandles`; both call `updateScene({ captureUpdate: CaptureUpdateAction.IMMEDIATELY })` so server writes are undoable. `sketchStore` ([src/lib/sketchStore.ts](src/lib/sketchStore.ts)) is the browser's localStorage-backed cache — it survives refresh; the server cache in `canvasBridge` is the cross-process source of truth. "Send to chat" exports a PNG, POSTs it to [`/api/design/snapshot`](src/app/api/design/snapshot/route.ts) which writes `${WORKSPACE_DIR}/design-scratch/<iso-ts>-<rand>.png`, then calls `chatBus.send` with a sentence pointing the chat brain at the saved file (the brain calls `vision_describe_canvas` if it needs to actually see the image).

- **Chat harness** ([src/app/api/chat/route.ts](src/app/api/chat/route.ts) + [src/components/ChatPanel.tsx](src/components/ChatPanel.tsx) + [src/lib/chatStore.ts](src/lib/chatStore.ts) + [src/lib/chatBus.ts](src/lib/chatBus.ts) + [src/lib/ai.ts](src/lib/ai.ts)): the right pane is the brain. `ChatPanel` uses `useChat` from `@ai-sdk/react` against `/api/chat`, hydrates `initialMessages` from `chatStore` (localStorage, keyed `tango:chat:v1:<workspacePath>`), and mirrors back on every message change. `id={workspacePath}` makes a workspace switch yield a fresh transcript. Load-bearing details:

  - **Smart routing by task type.** [src/lib/ai.ts](src/lib/ai.ts) exports `getModel(task: TaskType)` and `safeModel(task)` over a small registry: `orchestrate`/`code` → `anthropic('claude-sonnet-4-6')`, `fast-ui` → `anthropic('claude-haiku-4-5-20251001')`, `vision` → `google('gemini-2.5-pro')`, `summarize` → `openai('gpt-5.5')` (used by `memory.ts` for `Recent` rewrites). `safeModel` falls through providers when a key is missing.
  - **Sub-agent tools, not new MCP tools.** The route adds two AI-SDK *local* tools alongside the MCP tool set: `vision_describe_canvas` (calls `screenshot_canvas` MCP, then `generateText` on Gemini) and `synthesize_swiftui` (`generateText` on Sonnet). They live in the route because they need the route's MCP client and provider keys; promoting them to MCP would add a network round-trip for nothing. If you need to share them with an external MCP client, lift them then.
  - **Tool allowlist.** `/api/chat` filters `await client.tools()` through `ALLOWED_TOOLS` in [helpers.ts](src/app/api/chat/helpers.ts) — the 15 brain-side MCP tools (canvas, ui-mock, ios, `remember_note`). New MCP tools default to *not* visible; add to the set explicitly.
  - **Same-origin MCP.** The route builds the MCP URL from `req.url` (`${url.protocol}//${url.host}/mcp`). Don't hardcode `http://localhost:3000/mcp` — Electron loopback and proxied dev URLs both depend on this.
  - **MCP client is per-request.** `createMCPClient` is called inside `POST`, closed once via `closeOnce()` from `onFinish` and `onError`. Don't lift the client to module scope — sessions are HTTP-multiplexed on the server, but the client owns transport state that doesn't survive across requests cleanly.
  - **Memory log on finish.** `onFinish` collects the tool sequence (`name1→name2→…`) and the final text, then `appendEvent({type:'agent_run', goal, tools, outcome})`. Failures here must NOT break the response — the call is wrapped in try/catch.
  - **chatBus seam.** Feature panels never hold a `useChat` reference — they call `chatBus.send(text)` and ChatPanel handles delivery. Match this pattern when adding new "push to chat" entry points.

- **Simulator panel** ([src/server/sim.ts](src/server/sim.ts) + [src/app/api/sim/status/route.ts](src/app/api/sim/status/route.ts) + [src/components/SimulatorPanel.tsx](src/components/SimulatorPanel.tsx)): the right-most aside iframes [serve-sim](https://github.com/EvanBacon/serve-sim)'s preview UI so the user can drive a booted iOS Simulator without leaving tango. Single global helper per server run — not per-WS, not per-workspace, because `serve-sim` is a system-level resource that sees whatever simulator the user has booted via Xcode/`simctl`. Load-bearing details:

  - **Eager spawn at boot, only on darwin.** [server.ts](server.ts) calls `startSimHelper()` once after the workspace ensure step. On any other platform it's a no-op and `getSimStatus()` returns `{ phase: 'unsupported' }`. The browser panel polls `/api/sim/status` (1s for ~5 ticks, then 2.5s indefinitely) and renders the iframe once `phase === 'ready'`. There is no hard timeout — `npx`'s first-run install can take a while on a cold cache.
  - **Discriminated union state.** `SimStatus = { phase: 'unsupported' } | { phase: 'starting' } | { phase: 'ready'; url } | { phase: 'error'; message }` — never a struct with optional fields.
  - **Process-group teardown.** `spawn('npx', ['serve-sim'], { detached: true })` puts the child in its own pgid; `stopSimHelper` calls `process.kill(-pid, 'SIGTERM')` with a 2s SIGKILL escalation. SIGINT/SIGTERM/`exit` handlers in [server.ts](server.ts) all run `stopSimHelper`.
  - **Localhost-only URL parse.** `parsePreviewUrl` requires a `\n`-terminated banner AND validates the URL's hostname is `localhost` / `127.0.0.1` / `::1` before returning it.
  - **Iframe is sandboxed.** `sandbox="allow-scripts allow-same-origin allow-forms"`; deliberately no `allow-top-navigation`, no `allow-popups`.
  - **No simBus.** No duplex traffic from tango's React tree into the simulator; the iframe handles its own MJPEG/WS directly to serve-sim. If the chat brain ever needs to drive the simulator (tap, swipe, rotate, install), reach for an MCP tool that calls serve-sim's HTTP API instead of inventing a bus.
  - **Known limitation: loopback only.** `serve-sim` binds to localhost; opening tango at `http://10.0.0.5:3000` from another machine fails silently in the iframe.

## Workspace

The active workspace is resolved at boot and on every picker selection. Resolution order (in [src/server/workspace.ts](src/server/workspace.ts):`resolveWorkspaceAtBoot`):

1. `process.env.TANGO_WORKSPACE` — pinned, picker is read-only, source `'env'`.
2. `~/.tango/state.json#lastWorkspace` — last-picked, if it still exists. Source `'persisted'`.
3. `null` — picker shows blocking; `/api/design/snapshot` returns 409. Source `'unset'`.

The picker UI lives in [src/components/WorkspaceDialog.tsx](src/components/WorkspaceDialog.tsx) + [src/components/WorkspaceGate.tsx](src/components/WorkspaceGate.tsx). The user can click the workspace pill in [src/components/AppTopBar.tsx](src/components/AppTopBar.tsx) to switch mid-session. Mid-session switches: `setWorkspace` clears the canvasBridge cache, fires `broadcastWorkspaceChanged` server hook, and emits on the in-browser `workspaceBus` so [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) tears down its WS and reopens against the new cwd. ChatPanel re-hydrates from `chatStore` under the new workspace key automatically because `id={workspacePath}` is passed to `useChat` and the hydration `useEffect` re-runs.

Five things land in the chosen workspace, all non-destructive — these exist so users can also point the standalone `claude` CLI at the same folder, even though tango's own chat doesn't read them:

- **`.claude/tango.md`** — generated docs telling Claude about the `tango-canvas` MCP tools; **overwritten** every ensure. Wholly ours.
- **`CLAUDE.md`** — only a 3-line sentinel block (`<!-- tango:start … -->\n@.claude/tango.md\n<!-- tango:end -->`) is managed. Everything outside the block is preserved byte-for-byte.
- **`.mcp.json`** — **merged** under `mcpServers['tango-canvas']` to point at `http://localhost:<PORT>/mcp`. Other server entries preserved. Malformed JSON or wrong shape → `ensureWorkspace` **refuses** to write.
- **`.claude/settings.json`** — **merged** to add `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Preserves any other keys.
- **`design-scratch/`** — `mkdir -p`. PNGs from "Send to chat" land here.

The snapshot route calls `getWorkspaceOrNull()` (or `getWorkspace()` for the throwing variant) so all the file-paths the chat is told about resolve from the active workspace.

User-level state lives at `~/.tango/state.json` ([src/server/workspaceState.ts](src/server/workspaceState.ts)) — single key `lastWorkspace`. Electron will swap `os.homedir()` for `app.getPath('userData')` here; don't introduce other paths to that file.

## Layout

`react-resizable-panels` is **v4**, which renamed everything. Do not use v3 names from training data:

| v3 (training data)    | v4 (this project) |
|-----------------------|-------------------|
| `PanelGroup`          | `Group`           |
| `PanelResizeHandle`   | `Separator`       |
| `direction="..."`     | `orientation="..."` |
| `autoSaveId`          | `defaultLayout` + `onLayoutChanged` (manual storage) |

Sizes accept strings with units (`"35%"`, `"400px"`) or bare numbers (percent).

## Design system

The app uses a shadcn-style stack (Tailwind v4 + Radix + CVA + `cn()`). Two seams matter:

- **Primitives** live in [src/components/ui/](src/components/ui/) — `alert`, `button`, `input`, `dialog`, `dropdown-menu`, `select`, `tabs`, `tooltip`, `hover-card`, `command`, `accordion`, `badge`, `button-group`, `input-group`, `separator`, `spinner`, `textarea`. Higher-level chat composites live in [src/components/ai-elements/](src/components/ai-elements/). Tango-specific composites that aren't generic shadcn primitives live in [src/components/](src/components/) — notably [PanelHeader.tsx](src/components/PanelHeader.tsx), the shared chrome for every full-height panel (ChatPanel / Simulator / LeftPanel). All use `cn()` from [src/lib/utils.ts](src/lib/utils.ts) for class merging and CVA for variant systems.
- **Tokens** live in [src/app/globals.css](src/app/globals.css) — the `@theme inline` block exposes them as Tailwind utilities (`bg-background`, `text-muted-foreground`, `border-border`, etc.); the OKLCH values themselves sit in `:root` and `.dark` (currently inactive). Adding a new themable color = three edits in this one file.

**Rule for feature components: use semantic tokens, not raw Tailwind palette utilities.** No `bg-neutral-*` / `border-neutral-*` / `text-neutral-*` / hex literals in `src/components/*.tsx` or `src/app/*.tsx` outside the primitives. The semantic mapping is:

| When you want… | Use |
|---|---|
| Page surface | `bg-background` |
| Panel / card surface | `bg-card` |
| Raised tab/pill background | `bg-muted` |
| Selected/inverted button (light bg, dark text in dark mode) | `bg-foreground text-background` |
| Hover background | `bg-accent` |
| Hairlines | `border-border` |
| Body text | `text-foreground` |
| Slightly muted body text | `text-foreground/90` |
| Captions / labels / placeholders | `text-muted-foreground` |
| Very muted / decorative | `text-muted-foreground/60` |
| Selection / focus rings | `ring-ring/50` |
| Error / destructive surface | `bg-destructive text-destructive-foreground` (or `text-destructive` on inline error text, `<Alert variant="destructive">` for boxed errors) |
| Warning surface | `bg-warning text-warning-foreground` (or `<Alert variant="warning">` for boxed warnings, `<Button variant="warning">` for warning CTAs) |

Sky/info surfaces don't have a token yet — add one (`--info` / `--info-foreground` in `globals.css` + the matching `@theme inline` exposure) the first time you need it; don't reach for raw `bg-sky-*`.

**Adding a new primitive:** copy from upstream shadcn ([ui.shadcn.com](https://ui.shadcn.com)) into `src/components/ui/`, change the `cn` import path to `@/lib/utils`, leave everything else untouched.

## Conventions

- **MCP tools are the seam for AI capabilities.** Don't reach into `canvasBridge` or `uiMockBridge` from outside [server.ts](server.ts) / [src/server/mcp.ts](src/server/mcp.ts). New AI capabilities go on as new MCP tools so the chat brain (and any external MCP client like a side-running `claude` CLI) gets them. To expose a new tool to the chat, add its name to `ALLOWED_TOOLS` in [src/app/api/chat/helpers.ts](src/app/api/chat/helpers.ts) — by default a new MCP tool is invisible to the chat.
- **Sub-agent calls live as local AI-SDK tools, not new MCP tools.** When the chat needs to delegate to a different model (vision, code synthesis, classification), the right shape is a `tool({...})` defined inline in [src/app/api/chat/route.ts](src/app/api/chat/route.ts) whose `execute` does its own `generateText({ model: getModel('vision') })`. That keeps the orchestrator's transcript clean and means tests are pure vitest with `generateText` mocked. Promote to MCP only when an external MCP client also needs the capability.
- **Don't bypass `chatBus` / `canvasBus` / `uiMockBus`** by reaching into the WebSockets or `useChat` from outside the bus owner (`ChatPanel.tsx` / `SketchPanel.tsx` / `UIPanel.tsx`). Buses are the seams; future features (recording, multi-tab, alternate transports) hook them.
- **Don't import `@excalidraw/excalidraw` outside [DesignerCanvas.tsx](src/components/DesignerCanvas.tsx).** Excalidraw initializes against `window` at module load and dies on SSR — and on the server. The dynamic-import boundary lives in `SketchPanel`; other code reaches the canvas through [sketchStore](src/lib/sketchStore.ts), the `DesignerHandles` callback, or the `canvasBus`, never by touching the package directly. The server constructs Excalidraw scene JSON by hand instead.
- **Sanitize `appState` at every JSON boundary** via [`sanitizeAppState`](src/lib/canvasBus.ts). Excalidraw's appState contains `Map`/`Set` fields (`collaborators`, `pointers`, `followedBy`) that JSON.stringify silently flattens to `{}`; if that round-trips back into the canvas, Excalidraw crashes on `.forEach`. Anywhere we serialize, store, or transit appState, run it through the sanitizer.
- **`design-scratch/` is workspace scratch.** Lives at `<workspace>/design-scratch/`, gitignored. The active workspace is read via `getWorkspaceOrNull()` (route handlers must handle the `null` case — return 409, not crash) — never hardcode the path elsewhere. Electron will swap the path for `app.getPath('userData')` in one place.
- **Workspace files are merged, not overwritten.** `ensureWorkspace()` writes `.claude/tango.md` (overwrite, ours), merges a 3-line sentinel block into `CLAUDE.md` (preserves user content outside the block), merges `.mcp.json` under `mcpServers['tango-canvas']` (preserves other servers; refuses on malformed JSON), and merges `.claude/settings.json` (preserves hooks/theme/model; adds `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). The merge logic is exposed as pure helpers (`mergeClaudeMd`, `mergeMcpJson`, `mergeClaudeSettings`) — extend those, don't pile new effects into `ensureWorkspace`.
- **The workspace can be unset.** Don't reach for `getWorkspace()` (which throws) from a route handler or top-level module — use `getWorkspaceOrNull()` and handle null. The picker mounts on `/` for any user with no env-pinned workspace, so first-launch is *always* through the picker.
- **Don't mutate `currentWorkspace` directly.** `setWorkspace` in [src/server/workspaceState.ts](src/server/workspaceState.ts) is the only writer outside boot resolution — it validates the path, ensures the workspace files, persists to `~/.tango/state.json`, clears the canvas cache, and broadcasts the switch. Skipping any of those steps will leave the app inconsistent.
- **No `next dev`, no Vercel adapters, no edge runtime.** Custom Node server is load-bearing because the WSes and the MCP transport live in-process, and Electron will swap them for IPC against the same `attachCanvas` / `attachUIMock` / `mountMcp` surfaces.
- **Server-side singleton state goes on `globalThis`.** Next loads route handlers in a *different module graph* from the custom server (which is run by `tsx`, not Next). A plain module-scope `let state = …` gives you two independent copies: boot code in [server.ts](server.ts) writes one, the `/api/foo` route handler reads the other and sees the module-default forever. Stash anything a route handler needs to read on `globalThis['__tangoXxxSlot__']` with a lazy `getSlot()` initializer — see [src/server/workspace.ts](src/server/workspace.ts) (workspace path / source) and [src/server/sim.ts](src/server/sim.ts) (sim helper child + status) for the canonical shape.
- **External helpers go in their own process group.** Anything spawned via `child_process.spawn` that itself execs subprocesses (`npx`-style wrappers, shell scripts, `bunx`, `pnpm dlx`) must use `detached: true` and be torn down with `process.kill(-pid, signal)` plus a SIGKILL escalation timer. See [src/server/sim.ts](src/server/sim.ts) for the canonical shape.
- **Treat `npx`-fetched UI as untrusted in the iframe.** When mounting a third-party tool's UI (today: the simulator panel), validate any URL the helper hands us is loopback-only before iframing it, set the iframe's `sandbox` to drop `allow-top-navigation` and `allow-popups`, and don't share state with the parent unless via a known-good `postMessage` protocol.
- **Strict Mode is on.** Effect double-mounts in dev are expected — don't "fix" by disabling Strict Mode.
- **Test pure logic with vitest.** `npm test` runs the suite via [vitest.config.ts](vitest.config.ts); tests are co-located as `*.test.ts` next to the source. Default env is node; use `// @vitest-environment happy-dom` as line 1 for browser-shaped modules (`localStorage` etc.). Tier-1 covered surfaces — `mergeClaudeMd` / `mergeMcpJson` / `mergeClaudeSettings`, `sanitizeAppState`, `recentProjects`, the memory-file fence parser/formatters, the chat-route helpers (`lastUserGoal` / `mcpUrl` / `filterAllowedTools`), `getModel` / `safeModel`, `chatStore` / `chatBus`, and `validatePath` via `dryRunSetWorkspace` — are load-bearing pure functions with explicit invariants; if you change them, update or add tests. New pure logic should land with tests; reach for the existing fixtures (e.g. the `wellFormed()` builder in [src/server/memory.test.ts](src/server/memory.test.ts)) before inventing new ones. Run `npm test` before claiming a change is done.
- **Style with semantic tokens, not palette utilities.** See the **Design system** section above. Feature components use `bg-background` / `bg-card` / `text-foreground` / `text-muted-foreground` / `border-border` so a single edit in `globals.css` re-skins the app.

## Vision (so future changes don't paint into a corner)

1. **Now:** ChatPanel is the brain — a Vercel AI SDK chat harness that calls Anthropic for orchestration / code, Google for vision via the `vision_describe_canvas` sub-agent tool, OpenAI for memory summarization. MCP server gives it canvas / UI-mock / iOS / memory tools, all server-side. Designer mode is duplex over `/ws/canvas`. UI mock mode is duplex over `/ws/ui-mock`. Simulator sidebar iframes serve-sim for live iOS device preview on darwin. Conversation history is per-workspace in localStorage (`tango:chat:v1:<path>`).
2. **Next:** richer routing (`prepareStep`-driven Haiku swap when the next step is obviously fast UI work; classifier-tuned routing when the user goal lands in a clear bucket). More sub-agent tools (typography critique, palette extraction). Tool-call verification (e.g. `set_canvas_state` returns a fresh thumbnail so the brain self-corrects). MCP tools that drive the simulator (tap / swipe / rotate / install) so the chat can iterate on a mobile UI without the human in the loop. Same-origin mount of serve-sim's UI to drop the cross-port iframe and unblock LAN dev.
3. **Later:** package as Electron. The renderer drops the WSes and calls `attachCanvas` / `attachUIMock` / `mountMcp` equivalents over IPC; [designSnapshot.ts](src/lib/designSnapshot.ts) swaps its POST for direct `fs.writeFile` against `app.getPath('userData')`. The chat-store may move from localStorage to a real on-disk store. The rest of the React tree is unchanged.

## Files that matter

- [server.ts](server.ts) — Next + WS upgrade routing + MCP mount + boot-time workspace resolution
- [src/server/canvasBridge.ts](src/server/canvasBridge.ts) — server-side scene cache + `/ws/canvas` hub
- [src/server/uiMockBridge.ts](src/server/uiMockBridge.ts) — server-side UI mock cache + `/ws/ui-mock` hub
- [src/server/mcp.ts](src/server/mcp.ts) — `McpServer` + Streamable HTTP transport at `/mcp`; tool registrations
- [src/server/iosBuild.ts](src/server/iosBuild.ts) — `ios_status` / `ios_build_run` / `ios_logs_recent` backing
- [src/server/memory.ts](src/server/memory.ts) — workspace memory file (`tango-memory.md`) parser + `appendEvent` + LLM-driven `Recent` summarization
- [src/server/workspace.ts](src/server/workspace.ts) — workspace getter/setter + pure-function merges + `ensureWorkspace()`
- [src/server/workspaceState.ts](src/server/workspaceState.ts) — `~/.tango/state.json` reader/writer + `setWorkspace`
- [src/app/api/workspace/current/route.ts](src/app/api/workspace/current/route.ts) — GET active path + source
- [src/app/api/workspace/select/route.ts](src/app/api/workspace/select/route.ts) — POST set + ensure (or `dryRun:true` to validate-only)
- [src/app/api/chat/route.ts](src/app/api/chat/route.ts) — chat route: `streamText` + `@ai-sdk/mcp` client + sub-agent local tools (`vision_describe_canvas`, `synthesize_swiftui`) + memory log
- [src/app/api/chat/helpers.ts](src/app/api/chat/helpers.ts) — `ALLOWED_TOOLS` allowlist + `lastUserGoal` / `mcpUrl` / `filterAllowedTools`
- [src/lib/ai.ts](src/lib/ai.ts) — provider registry (`getModel(task)`, `safeModel(task)`, `MODEL_IDS`); back-compat `openai` / `VISION_MODEL` re-exports for `memory.ts`
- [src/components/ChatPanel.tsx](src/components/ChatPanel.tsx) — `useChat` against `/api/chat`; localStorage hydration via `chatStore`; `chatBus` listener; tool-result rendering
- [src/lib/chatStore.ts](src/lib/chatStore.ts) — workspace-keyed localStorage (`tango:chat:v1:<path>`); MAX_MESSAGES + MAX_BYTES caps
- [src/lib/chatBus.ts](src/lib/chatBus.ts) — feature-panel → ChatPanel pubsub seam (`chatBus.send(text)`)
- [src/lib/canvasBus.ts](src/lib/canvasBus.ts) — in-app pubsub seam (canvas) + `sanitizeAppState`
- [src/lib/uiMockBus.ts](src/lib/uiMockBus.ts) — in-app pubsub seam (ui mock)
- [src/components/WorkspaceGate.tsx](src/components/WorkspaceGate.tsx) — context provider + dialog portal; first-launch blocking picker
- [src/components/WorkspaceDialog.tsx](src/components/WorkspaceDialog.tsx) — picker dialog
- [src/lib/recentProjects.ts](src/lib/recentProjects.ts) — localStorage-backed recents list (`tango.workspace.recent`, capped 8)
- [src/lib/workspaceBus.ts](src/lib/workspaceBus.ts) — in-browser pubsub for `workspaceChanged`
- [src/app/page.tsx](src/app/page.tsx) — split-pane layout: LeftPanel + ChatPanel + (optional) SimulatorPanel
- [src/components/AppTopBar.tsx](src/components/AppTopBar.tsx) — chat / simulator toggles, workspace pill
- [src/components/LeftPanel.tsx](src/components/LeftPanel.tsx) — Sketch / Moodboard / UI mode tabs
- [src/components/SketchPanel.tsx](src/components/SketchPanel.tsx) — SSR-safe parent: toolbar, "Send to chat", `/ws/canvas` socket, dynamic-imports the canvas
- [src/components/UIPanel.tsx](src/components/UIPanel.tsx) — UI mock parent: toolbar, "Send to chat", `/ws/ui-mock` socket
- [src/components/MoodboardPanel.tsx](src/components/MoodboardPanel.tsx) — moodboard mode: image gen + handoff to chat
- [src/components/DesignerCanvas.tsx](src/components/DesignerCanvas.tsx) — Excalidraw wrapper; the only file that imports `@excalidraw/excalidraw`
- [src/lib/sketchStore.ts](src/lib/sketchStore.ts) — plain-module canvas state (localStorage-backed)
- [src/lib/uiMockStore.ts](src/lib/uiMockStore.ts) — UI mock spec localStorage cache
- [src/lib/designSnapshot.ts](src/lib/designSnapshot.ts) — write-snapshot adapter (web POSTs; Electron will swap to `fs.writeFile`)
- [src/app/api/design/snapshot/route.ts](src/app/api/design/snapshot/route.ts) — POST handler that writes PNGs to `${WORKSPACE_DIR}/design-scratch/`
- [src/server/sim.ts](src/server/sim.ts) — process-group child manager for `npx serve-sim`
- [src/app/api/sim/status/route.ts](src/app/api/sim/status/route.ts) — GET wrapper for `getSimStatus()`
- [src/components/SimulatorPanel.tsx](src/components/SimulatorPanel.tsx) — sandbox-iframed serve-sim preview
