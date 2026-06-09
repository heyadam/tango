@AGENTS.md

# tango

Split-pane design-prototype app: a direct-manipulation design canvas on the left (screens of absolutely-positioned shadcn/Tailwind components — drag, resize, text-edit), an agent pane on the right — by default the **built-in tango agent** (a Claude Agent SDK session rendered as chat), with `claude` / `codex` CLIs in an xterm.js PTY as alternatives — and an optional iOS Simulator mirror in a third pane. The core loop: **import** mobile code onto the canvas (the Import button runs a dedicated direct-API loop — see fast import below) → **edit** directly → **live-preview** natively on the simulator in <1s via the preview-host app (no rebuild) → **export** deterministically to SwiftUI and build/launch (`export_run`, no LLM).

Stack: **Next.js 16 (App Router) + React 19 + Tailwind v4**, custom Node server, WebSocket bridges to the built-in agent / `node-pty` / the design spec / the preview host, in-process MCP server giving every agent tools to drive the canvas and the iOS toolchain, the **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`) for the built-in agent, the **Anthropic SDK** (`@anthropic-ai/sdk`) for the fast-import loop, and a small committed **SwiftUI preview-host app** ([preview-host/](preview-host/)). Will eventually be packaged as an Electron app — keep that path open (no Vercel-only assumptions, no edge runtime).

The repo and the workspace the terminal agent operates in are **separate directories** by design. This repo is for tango itself; the workspace is whatever folder the user picks in the in-app picker (or the path pinned by `TANGO_WORKSPACE`). See **Workspace** below.

## Run / build

```
npm run dev      # tsx server.ts on :3000
npm run build    # next build (server stays the same)
npm start        # production server
npm test         # vitest run
npm run test:watch
```

The dev script runs the **custom server**, not `next dev`. Do not change to `next dev` — it will break the WebSocket bridges.

On boot the server resolves the active workspace (env var → persisted `~/.tango/state.json` → null). When a workspace is set, it's ensured non-destructively: `.claude/tango.md` + 4 skills (overwrite), `CLAUDE.md` / `AGENTS.md` (sentinel blocks only — user content preserved byte-for-byte outside them), `.mcp.json` (merge under `mcpServers['tango-canvas']` — refuses on malformed JSON), `.claude/settings.json` (merge), `.tango/` scaffold (targeted `.gitignore`), `tango-memory.md` (create-if-absent) — then the design spec hydrates from `.tango/design.json`. If no workspace is set, the browser shows a blocking picker and the PTY refuses to spawn until one is chosen.

## Architecture (non-obvious bits)

```
browser ──HTTP──►  Next request handler                                  ┐
browser ──HTTP──►  /mcp                StreamableHTTPServerTransport     │
browser ──HTTP──►  /api/ios/export-run → runExportAndRun()               │── server.ts (one Node process)
browser ──HTTP──►  /api/ui/import      → runUiImport() (fast import)     │
browser ──HTTP──►  /api/preview/*      → previewHost lifecycle           │
browser ──HTTP──►  /api/sim/status     → getSimStatus()                  │
browser ──WS────►  /ws/agent           → attachAgent (built-in agent)    │
browser ──WS────►  /ws/terminal        → attachPty (claude/codex CLIs)   │
browser ──WS────►  /ws/ui-mock         → attachUIMock                    │
simulator ─WS───►  /ws/preview         → attachPreview                   ┘
                            ↓                        ↓
        Agent SDK session / node-pty          uiMockBridge cache (authoritative)
        cwd: WORKSPACE_DIR                    ⇄ .tango/design.json (write-behind persist)
        tools via /mcp (both paths)           → previewBridge → preview-host app
```

On darwin, server boot also calls `startSimHelper()` once (`npx serve-sim`, iframed into the right-most panel).

- **Custom server** ([server.ts](server.ts)): hosts Next, four `WebSocketServer({ noServer: true })` (agent, terminal, ui-mock, preview), and the MCP transport. The `'upgrade'` listener routes the four WS paths; everything else (HMR, etc.) goes to `app.getUpgradeHandler()`. `mountMcp()` shims the `'request'` listener so `/mcp` goes to the MCP transport before falling through to Next. Both `getRequestHandler()` and `getUpgradeHandler()` **must be called inside `app.prepare().then(...)`**. `TANGO_REPO_ROOT` is derived via `fileURLToPath(import.meta.url)` — **`import.meta.dirname` is undefined under tsx's transform**; don't switch back.

- **Built-in agent bridge** ([src/server/agentBridge.ts](src/server/agentBridge.ts) + [src/lib/agentProtocol.ts](src/lib/agentProtocol.ts) + [src/components/AgentPanel.tsx](src/components/AgentPanel.tsx)): the default agent pane. One Claude Agent SDK `query()` session per `/ws/agent` connection — streaming-input mode, `cwd` = workspace, `permissionMode: 'bypassPermissions'`, `systemPrompt: {preset: 'claude_code', append}` (so workspace CLAUDE.md / tango.md still load), `skills: 'all'` (discovers the workspace's `.claude/skills`), and **tools via the same `/mcp` HTTP endpoint external CLIs use** — keep it that way so the built-in agent and external agents can't drift. Wire protocol is small JSON frames (`user_message`/`interrupt` in; `ready`/`text_delta`/`tool_use`/`turn_done`/control frames out) defined in `agentProtocol.ts`. Sessions resume across restarts (`~/.tango/state.json#agentSessions`, keyed by workspace). `warmAgentEngine()` pre-warms one engine subprocess (`startup()`) per workspace so the first message skips the cold start; discarded + re-warmed on workspace switch. Model: `claude-sonnet-4-6` by default (speed/cost for the interactive loop; `TANGO_AGENT_MODEL` to override). Auth: the SDK needs `ANTHROPIC_API_KEY` (or the engine's own login state). AgentPanel subscribes to `terminalBus` via `createSubmitBuffer` so UIPanel's Send/Import-shaped writes (text + `\r`) arrive as whole messages.

- **PTY bridge** ([src/server/pty.ts](src/server/pty.ts)): one `node-pty` process per WS connection, spawned in the workspace, auto-running the selected terminal agent ([src/server/terminalAgent.ts](src/server/terminalAgent.ts) builds the launch command; [src/server/ptyEnv.ts](src/server/ptyEnv.ts) injects `.tango/bin` into PATH + the MCP URL). Used for the `claude` / `codex` CLI agents only — the `tango` agent never opens a PTY (a direct `/ws/terminal` hit while it's selected falls back to launching Claude Code). Wire protocol: server→client binary = raw pty bytes; client→server binary = keystrokes; client→server text = JSON control (`resize`). Keep new control messages on the text channel.

- **Fast import** ([src/server/uiImport.ts](src/server/uiImport.ts) + [/api/ui/import](src/app/api/ui/import/route.ts)): the Import button's path — a dedicated direct-API agentic loop (`@anthropic-ai/sdk`, manual tool loop, streaming) instead of the general agent. Frozen system prompt carries the SwiftUI→UINode mapping rules with a `cache_control` breakpoint (repeat imports read it from prompt cache); two tools: `read_swift_file` (allowlisted to the scanned file list) and `emit_screen` (validated against `uiScreenSchema`, applied to the **live** spec replace-or-append so screens stream onto the canvas one by one). `TangoGenerated/` screen files are scanned as **round-trippable design exports** (their `.frame/.offset` coords and `screen=<id>` headers are literal) — when the canvas lost those screens, re-importing them is how the design comes back. State machine on a `globalThis` slot polled by the browser — same shape as Export & Run. Runs in the route-handler graph, so spec reads/writes go through the `getUiMockSpec`/`setUiMockSpec` hooks — **never import `uiMockBridge` from the route graph** (its module-load `registerHook` calls would re-point the hooks at a copy with an empty cache). Model: `claude-opus-4-8` (override with `TANGO_IMPORT_MODEL`); needs `ANTHROPIC_API_KEY`.

- **Design spec + bridge** ([src/server/uiMockBridge.ts](src/server/uiMockBridge.ts) ↔ [src/lib/uiMockBus.ts](src/lib/uiMockBus.ts) ↔ [src/components/UIPanel.tsx](src/components/UIPanel.tsx)/[UIMockCanvas.tsx](src/components/UIMockCanvas.tsx)): the `UISpec` (screens of flat, absolutely-positioned `UINode`s — see [src/lib/uiMockProtocol.ts](src/lib/uiMockProtocol.ts)) lives in the server-side cache; the browser is the source of truth for human edits (drag/resize/text snapshots, debounced 250ms), MCP tools for AI edits. Last-writer-wins, no CRDT. Node-level MCP mutations apply pure ops from [src/lib/uiMockOps.ts](src/lib/uiMockOps.ts) to the **live** cache so user tweaks to other nodes survive. The bridge's `cacheChanged()` choke point fans every change out to: browser broadcast (when server-initiated), the preview host (always), and the write-behind persist (always).

- **Spec persistence** ([src/server/uiMockPersist.ts](src/server/uiMockPersist.ts)): debounced (750ms) atomic write of the cache to `<workspace>/.tango/design.json`, hydrated back at boot and on workspace switch. **`schedulePersist` captures `(workspace, spec)` at schedule time and keys pending writes by workspace** — a mid-debounce workspace switch can never write the new workspace's cache into the old file. `flushPersistSync` runs on `process.on('exit')`. Invalid files are renamed aside (`design.invalid-<ts>.json`), never destroyed. The cache stays runtime-authoritative; nothing reads the file at request time.

- **Style resolver** ([src/lib/uiResolve.ts](src/lib/uiResolve.ts) + [themeColors.ts](src/lib/themeColors.ts) + [lucideToSfSymbol.ts](src/lib/lucideToSfSymbol.ts)): flattens per-kind baselines (mirroring [UIMockNode.tsx](src/components/UIMockNode.tsx) and the shadcn button/badge variants) → the supported Tailwind subset from `className` → inline `style` into concrete `ResolvedStyle` structs (RGBA colors, px sizes, SF Symbol names). **Both** the SwiftUI codegen and the preview wire protocol consume it — all CSS/Tailwind knowledge lives here so the two render paths can't drift and Swift stays dumb. `TANGO_THEME` mirrors the `:root` OKLCH palette in [globals.css](src/app/globals.css) — keep them in lockstep.

- **SwiftUI codegen** ([src/lib/specToSwiftUI.ts](src/lib/specToSwiftUI.ts)): deterministic spec → Swift files (same input = byte-identical output; golden-file tested, goldens verified with `swiftc -typecheck`). Layout convention shared with the preview renderer: `ZStack(alignment: .topLeading)` + `.frame(width:height:).offset(x:y:)` — **never `.position`** (center-based, off-by-half trap). >10 nodes are chunked into `Group{}`s (ViewBuilder's limit). Every file opens with a `tango:generated` marker — load-bearing: export deletes stale marked files and never touches unmarked ones. Generated type names are `Tango`-prefixed so they can't collide with user Views.

- **Export & Run** ([src/server/iosExport.ts](src/server/iosExport.ts) + [/api/ios/export-run](src/app/api/ios/export-run/route.ts)): codegen → write into `<source root>/TangoGenerated/` → `iosBuildRun()` (incremental xcodebuild → simctl install → terminate → launch). State machine on a `globalThis` slot, polled by the browser (no SSE — matches the SimulatorPanel pattern, phases are coarse and build-dominated). `resolveGeneratedDir` detects Xcode 16 `PBXFileSystemSynchronizedRootGroup` projects (`inclusion: 'fs-synced'`, auto-included) vs legacy (`'manual-add-required'` — surfaced to the user; **never auto-edit a pbxproj**). `resolveBuildProject` is shared with the `ios_build_run` MCP tool so project resolution can't drift.

- **Preview host** ([preview-host/](preview-host/) + [src/server/previewBridge.ts](src/server/previewBridge.ts) + [src/server/previewHost.ts](src/server/previewHost.ts)): a committed, hand-authored Xcode 16 project (objectVersion 77, fs-synced `Sources/`, shared scheme — `xcodebuild -scheme` requires it) whose app connects from the simulator to `ws://localhost:<port>/ws/preview` (the simulator shares the host network stack; `NSAllowsLocalNetworking` in its Info.plist allows cleartext ws). `previewBridge` re-resolves and broadcasts the **whole** resolved spec on every cache change (a few KB; no diffing keeps Swift dumb) and replays the last frame to (re)connecting clients. Lifecycle: build once per machine into `~/.tango/preview-host-build`, `simctl install`, then launch with **`SIMCTL_CHILD_TANGO_WS_PORT=<port>`** (simctl strips the prefix and passes the env). The Swift renderer is total: unknown node kinds → placeholder box, malformed frames → keep last good spec, reconnect with 0.5→5s backoff. The browser reports the user's working screen (`active_screen` on `/ws/ui-mock`) and the simulator follows it (`show_screen`).

- **MCP server** ([src/server/mcp.ts](src/server/mcp.ts)): in-process `McpServer` + `StreamableHTTPServerTransport` (SDK v1) at `/mcp`. 22 tools: 10 design (`get_ui_mock`, `get_ui_viewport`, `get_ui_layers`, `set_ui_mock`, `add_ui_screen`, `add_ui_nodes`, `update_ui_node`, `remove_ui_node`, `reorder_ui_node`, `clear_ui_mock`), 9 iOS (`ios_status`, `ios_build_run`, `ios_logs_recent`, `ios_inspect`, `ios_tap`, `ios_gesture`, `ios_button`, `ios_type`, `ios_rotate`), the 2 loop tools (`export_run`, `preview_start`), and `remember_note`. Per-session map keyed by `mcp-session-id`; localhost-only DNS rebinding protection. **Mounted on the bare `http.createServer`, not under `app/api/.../route.ts`** — the SDK transport wants Node `IncomingMessage`/`ServerResponse`. **`transport.onclose` must NOT call `mcpServer.close()`** — infinite recursion; just drop the session-map entry. The MCP server name stays `tango-canvas` — renaming it orphans the managed entry in every existing workspace's `.mcp.json`.

- **terminalBus** ([src/lib/terminalBus.ts](src/lib/terminalBus.ts)): in-browser pubsub seam between the left panel and the Terminal component. `sendToTerminal(text)` writes raw; `submitToTerminal(text)` writes text and `\r` as **two separate writes** (~120ms apart — a fused chunk gets treated as a paste by the agent TUI and the Enter doesn't fire). The `_onSend` / `_emitOutput` underscore methods are wired by `Terminal.tsx` only.

- **Terminal component** ([src/components/Terminal.tsx](src/components/Terminal.tsx)): must stay client-only (`dynamic(..., { ssr: false })` — xterm.js explodes on SSR). Resize is a debounced `ResizeObserver` (50ms) → `fitAddon.fit()` → JSON resize message.

- **Canvas components**: [UIPanel.tsx](src/components/UIPanel.tsx) is the left panel — owns the `/ws/ui-mock` socket, the PanelHeader toolbar (Import / Clear / Preview / Export & Run / Send), viewport reporting, and dynamic-imports [UIMockCanvas.tsx](src/components/UIMockCanvas.tsx) (react-moveable touches `window` at module load — keep the `ssr: false` boundary; a module-scope eager `import()` warms the chunk in parallel with the workspace fetch). `UIMockNode` and the per-node wrapper are `React.memo`'d — `uiMockOps` preserves node identity for untouched nodes and every callback prop is `useCallback`-stable; keep it that way or drags re-render the whole canvas.

- **Simulator panel** ([src/server/sim.ts](src/server/sim.ts) + [src/components/SimulatorPanel.tsx](src/components/SimulatorPanel.tsx)): iframes serve-sim's preview UI, darwin only, one global helper per server run. Discriminated-union status, process-group teardown (`detached: true`, `process.kill(-pid)` + SIGKILL escalation), localhost-only URL validation, sandboxed iframe. The `ios_*` control tools drive the simulator through serve-sim's HTTP API ([src/server/iosSimControl.ts](src/server/iosSimControl.ts)).

- **Workspace memory** ([src/server/memory.ts](src/server/memory.ts)): `tango-memory.md` with fenced Summary/Recent/user sections. Notes append via the `remember_note` tool; when Recent overflows, older entries **fold deterministically** into Summary (verbatim move, 16KB cap, oldest dropped) — no LLM involved. The user block is never touched; malformed files are rescued into it, never destroyed.

## Workspace

Resolution order (in [src/server/workspace.ts](src/server/workspace.ts):`resolveWorkspaceAtBoot`):

1. `process.env.TANGO_WORKSPACE` — pinned, picker is read-only, source `'env'`.
2. `~/.tango/state.json#lastWorkspace` — last-picked, if it still exists. Source `'persisted'`.
3. `null` — picker shows blocking; PTY and built-in agent refuse to spawn (`/ws/terminal` and `/ws/agent` close with 4001). Source `'unset'`.

The picker UI lives in [WorkspaceDialog.tsx](src/components/WorkspaceDialog.tsx) + [WorkspaceGate.tsx](src/components/WorkspaceGate.tsx). Mid-session switches (`setWorkspace` in [src/server/workspaceState.ts](src/server/workspaceState.ts)): validates the path, ensures the workspace files, persists, flushes + rehydrates the design spec (`resetUiMock` hook), and broadcasts `workspace_changed` so Terminal and UIPanel tear down and reopen their WSes.

Managed files in the workspace (all non-destructive): `.claude/tango.md` (overwrite, ours — describes the tool surface + design loop + ownership rule), 4 skills under `.claude/skills/` (`tango-ui-mock`, `tango-ui-import`, `tango-swiftui`, `tango-ios-sim` — retired skills are best-effort removed from old workspaces, which is load-bearing: stale skills advertise deleted tools), the `.agents/skills/` Codex mirrors + `AGENTS.md` sentinel, the `CLAUDE.md` sentinel block, `.mcp.json` merge, `.claude/settings.json` merge, `.tango/` (targeted `.gitignore` so `design.json` is committable while `DerivedData/`/`bin/` stay ignored; the exact-`*\n` legacy gitignore is migrated), and `tango-memory.md`. The merge logic is pure (`mergeClaudeMd`, `mergeAgentsMd`, `mergeMcpJson`, `mergeClaudeSettings`) — extend those, don't pile effects into `ensureWorkspace`.

User-level state lives at `~/.tango/state.json` (keys: `lastWorkspace`, `terminalAgent`, `agentSessions` — built-in agent session id per workspace). Electron will swap `os.homedir()` for `app.getPath('userData')` here; don't introduce other paths to that file.

## Design system

The app uses a shadcn-style stack (Tailwind v4 + Radix + CVA + `cn()`).

- **Primitives** live in [src/components/ui/](src/components/ui/). Tango-specific composites live in [src/components/](src/components/) — notably [PanelHeader.tsx](src/components/PanelHeader.tsx), the shared chrome for full-height panels.
- **Tokens** live in [src/app/globals.css](src/app/globals.css) — `@theme inline` exposes them as utilities; the OKLCH values sit in `:root` (tango brand palette: navy fg, cream bg, purple primary, mint secondary) and `.dark` (inactive). **If you change `:root`, update `TANGO_THEME` in [src/lib/themeColors.ts](src/lib/themeColors.ts) in lockstep** — the codegen and preview host render from it.

**Rule for feature components: use semantic tokens, not raw Tailwind palette utilities** (`bg-background`, `bg-card`, `text-foreground`, `text-muted-foreground`, `border-border`, `ring-ring/50`, `bg-destructive text-destructive-foreground`, `bg-warning text-warning-foreground`…). No `bg-neutral-*` / hex literals in `src/components/*.tsx` or `src/app/*.tsx` outside the primitives.

**Known exception**: [src/components/Terminal.tsx](src/components/Terminal.tsx) — xterm's theme can't consume CSS variables; hex literals stay until a `getComputedStyle` shim lands. New non-CSS surfaces should pull values from CSS variables (or `TANGO_THEME`) at init time.

**Adding a new primitive:** copy from upstream shadcn into `src/components/ui/`, change the `cn` import path to `@/lib/utils`, leave everything else untouched.

## node-pty caveat (will bite again)

`npm install` extracts `node_modules/node-pty/prebuilds/<plat>/spawn-helper` **without** the executable bit, which makes `pty.spawn` crash with `posix_spawnp failed` at runtime — not at install time. The `postinstall` script ([scripts/fix-node-pty.js](scripts/fix-node-pty.js)) re-applies `chmod +x`; on a fresh-clone failure run it manually or `npm rebuild`.

## Conventions

- **MCP tools are the seam for AI capabilities.** Don't reach into `uiMockBridge` / `previewBridge` from outside [server.ts](server.ts) / [src/server/mcp.ts](src/server/mcp.ts). New AI capabilities land as MCP tools so the terminal agent gets them automatically — and get documented in `TANGO_MD_HEAD` / the skills in [src/server/workspace.ts](src/server/workspace.ts), or agents won't know they exist.
- **The hybrid translation rule.** Canvas → code is deterministic (`specToSwiftUI` + `export_run`); code → canvas is agent-mediated (`tango-ui-import` skill). Don't add an LLM to the export path, and don't try to parse arbitrary hand-written SwiftUI deterministically — that asymmetry is the design.
- **`TangoGenerated/` is tango-owned.** Overwritten on every export; the `tango:generated` header marker is what makes stale-file cleanup safe. Never auto-edit a user's pbxproj — surface `manual-add-required` instead.
- **One styling brain.** Any new visual property flows: `UIMockNode` render → `uiResolve` baseline/parse → codegen emitter → preview-host `NodeView`. If you touch one, touch all four (the golden files + a sim screenshot will catch drift).
- **Don't bypass `terminalBus` / `uiMockBus`** by reaching into the WebSockets from outside `Terminal.tsx` / `UIPanel.tsx`. Buses are the seams; future features (recording, multi-tab, Electron IPC) will hook them.
- **Bridge to the agent pane via `submitToTerminal` for intentional asks** (Send) — it writes text + `\r` as two PTY writes; the chat panel reassembles them via `createSubmitBuffer`, so one bus serves both panel kinds. Never write a bare path into the PTY (the shell executes it on the next Return); prefix informational pings with `#`.
- **Server-side singleton state goes on `globalThis`.** Next loads route handlers in a *different module graph* from the custom server (run by `tsx`). Plain module-scope state silently forks into two copies — boot code writes one, the route handler reads the other. Use the `getSlot()` pattern ([workspace.ts](src/server/workspace.ts), [sim.ts](src/server/sim.ts), [iosExport.ts](src/server/iosExport.ts), [previewHost.ts](src/server/previewHost.ts)) and the typed hook registry ([serverHooks.ts](src/server/serverHooks.ts)) for cross-graph calls.
- **External helpers go in their own process group** (`detached: true`, kill with `process.kill(-pid)` + SIGKILL escalation): serve-sim, xcodebuild. Register `process.on('exit')` cleanup. Discriminated-union state (`{phase: …}`) over structs-with-optional-fields.
- **Treat `npx`-fetched UI as untrusted in the iframe** (serve-sim): loopback-only URL validation, sandboxed iframe, no `allow-top-navigation`/`allow-popups`.
- **The workspace can be unset.** Use `getWorkspaceOrNull()` from route handlers and handle null (409, not crash). Don't mutate `currentWorkspace` directly — `setWorkspace` is the only writer outside boot resolution.
- **No `next dev`, no Vercel adapters, no edge runtime.** The custom Node server is load-bearing; Electron will swap the WSes for IPC against the same `attachPty` / `attachUIMock` / `attachPreview` / `mountMcp` surfaces.
- **Strict Mode is on.** The terminal/agent effects run twice in dev → one harmless "WebSocket is closed before the connection is established" warning per mount, the agent CLI boots twice on first load (the first PTY is killed by the Strict-Mode cleanup), and the built-in agent engine spawns twice (the first is interrupted; the warm spare absorbs one of them). Don't "fix" by disabling Strict Mode.
- **Test pure logic with vitest** (`npm test`; co-located `*.test.ts`; `// @vitest-environment happy-dom` as line 1 for browser-shaped modules). Load-bearing covered surfaces: the workspace merge helpers, `uiMockOps`/`uiMockDefaults`, `sanitizeNodeStyle`, the memory fence parser + deterministic fold, `uiMockPersist` (round-trip, debounce-capture semantics), `themeColors`/`uiResolve`/`lucideToSfSymbol`, `specToSwiftUI` (golden files + determinism + escaping), `resolveGeneratedDir`/`writeGeneratedFiles`, `runExportAndRun` (DI state machine), `ptyEnv`/`terminalAgent`, `recentProjects`, and `validatePath` via `dryRunSetWorkspace`. If you change them, update or add tests; run `npm test` before claiming a change is done. After touching the codegen, also `swiftc -typecheck` the regenerated goldens against the iOS simulator SDK.
- **Style with semantic tokens, not palette utilities.** See the **Design system** section above.

## Vision (so future changes don't paint into a corner)

1. **Now:** one design surface, durable per-workspace specs (`.tango/design.json`), sub-second native preview on the simulator, deterministic export to SwiftUI (`TangoGenerated/`), agent-mediated import, and full simulator control for the terminal agent.
2. **Next:** editor depth (undo/redo history, marquee select, alignment guides, copy/paste, an inspector panel); mid-drag preview streaming (a transient `node_offset` channel on `/ws/preview`); smarter export (infer VStack/HStack from coords as an opt-in agent pass over `TangoGenerated/`); per-screen export; multi-workspace tabs.
3. **Later:** package as Electron. The renderer drops the WSes and calls `attachPty` / `attachUIMock` / `attachPreview` / `mountMcp` equivalents over IPC; `~/.tango` paths swap to `app.getPath('userData')`. The rest of the React tree is unchanged.

## Files that matter

- [server.ts](server.ts) — Next + WS upgrade routing + MCP mount + boot-time workspace resolution + spec hydration + agent pre-warm + exit flush
- [src/server/agentBridge.ts](src/server/agentBridge.ts) / [src/lib/agentProtocol.ts](src/lib/agentProtocol.ts) / [src/components/AgentPanel.tsx](src/components/AgentPanel.tsx) — built-in agent: Claude Agent SDK session over `/ws/agent`, wire protocol, chat panel
- [src/server/uiImport.ts](src/server/uiImport.ts) / [/api/ui/import](src/app/api/ui/import/route.ts) — fast import engine (direct-API loop, frozen cached prompt, `emit_screen` validation)
- [src/server/pty.ts](src/server/pty.ts) / [ptyEnv.ts](src/server/ptyEnv.ts) / [terminalAgent.ts](src/server/terminalAgent.ts) — terminal bridge + agent launch commands (claude/codex CLIs)
- [src/server/uiMockBridge.ts](src/server/uiMockBridge.ts) — authoritative spec cache, `/ws/ui-mock` hub, `cacheChanged()` fan-out, active-screen tracking
- [src/server/uiMockPersist.ts](src/server/uiMockPersist.ts) — `.tango/design.json` write-behind persistence
- [src/server/previewBridge.ts](src/server/previewBridge.ts) / [previewHost.ts](src/server/previewHost.ts) — `/ws/preview` hub + preview-host build/install/launch lifecycle
- [src/server/iosExport.ts](src/server/iosExport.ts) — Export & Run state machine, `resolveGeneratedDir`, `writeGeneratedFiles`, shared `resolveBuildProject`
- [src/server/iosBuild.ts](src/server/iosBuild.ts) / [iosSimControl.ts](src/server/iosSimControl.ts) / [sim.ts](src/server/sim.ts) — xcodebuild/simctl orchestration, simulator control, serve-sim helper
- [src/server/mcp.ts](src/server/mcp.ts) — the 22 MCP tools
- [src/server/workspace.ts](src/server/workspace.ts) / [workspaceState.ts](src/server/workspaceState.ts) — workspace ensure (generated docs + skills) + state/switching
- [src/server/memory.ts](src/server/memory.ts) — `tango-memory.md` (fence parser + deterministic fold)
- [src/server/serverHooks.ts](src/server/serverHooks.ts) / [wsHub.ts](src/server/wsHub.ts) / [fsAtomic.ts](src/server/fsAtomic.ts) — cross-module-graph hooks, WS fan-out primitive, atomic writes
- [src/lib/uiMockProtocol.ts](src/lib/uiMockProtocol.ts) / [uiMockSchema.ts](src/lib/uiMockSchema.ts) / [uiMockOps.ts](src/lib/uiMockOps.ts) / [uiMockDefaults.ts](src/lib/uiMockDefaults.ts) — spec types, zod schemas, pure ops, palette defaults
- [src/lib/uiResolve.ts](src/lib/uiResolve.ts) / [themeColors.ts](src/lib/themeColors.ts) / [lucideToSfSymbol.ts](src/lib/lucideToSfSymbol.ts) — the shared styling brain
- [src/lib/specToSwiftUI.ts](src/lib/specToSwiftUI.ts) — deterministic codegen (golden-file tested)
- [src/components/UIPanel.tsx](src/components/UIPanel.tsx) / [UIMockCanvas.tsx](src/components/UIMockCanvas.tsx) / [UIMockNode.tsx](src/components/UIMockNode.tsx) / [UIAddPalette.tsx](src/components/UIAddPalette.tsx) / [UILayersPanel.tsx](src/components/UILayersPanel.tsx) — the design canvas
- [src/components/Terminal.tsx](src/components/Terminal.tsx) + [src/lib/terminalBus.ts](src/lib/terminalBus.ts) — xterm + bus seam
- [src/app/page.tsx](src/app/page.tsx) — layout: agent | design canvas | simulator
- [preview-host/](preview-host/) — the committed SwiftUI preview app (its README documents the wire protocol)
- [scripts/fix-node-pty.js](scripts/fix-node-pty.js) — postinstall workaround
