# tango

A design-prototype app for building mobile UI with terminal-based coding agents. The left pane is a direct-manipulation design canvas — screens of real shadcn/Tailwind components you drag, resize, and text-edit, OpenPencil-style. The right pane is a real interactive terminal running the selected agent (`claude` by default, switchable to `codex`) in your chosen workspace. An optional further-right sidebar mirrors a booted iOS Simulator via [serve-sim](https://github.com/EvanBacon/serve-sim).

The loop tango is built around:

1. **Import** — the terminal agent reads your workspace's SwiftUI screens onto the canvas.
2. **Edit** — you (and the agent, via MCP tools) manipulate the design directly.
3. **Live preview** — a tiny native preview app on the simulator mirrors every canvas edit in **under a second**, no rebuild.
4. **Export & Run** — one click deterministically generates SwiftUI into `TangoGenerated/` in your Xcode project and builds/installs/launches it. No LLM in that path.

The repo is **tango itself**. The directory tango operates on (where the terminal agent's shell runs, where the design spec persists) is a separate workspace you pick from the in-app picker on first launch.

## Stack

- **Next.js 16** (App Router) on a **custom Node server** — `next dev` is not used; the WebSocket bridges and MCP transport live in-process.
- **React 19** + **Tailwind v4** + a shadcn-style primitive layer in [src/components/ui/](src/components/ui/); **react-moveable** for canvas drag/resize.
- **node-pty** for the terminal, bridged over `/ws/terminal`.
- **`@modelcontextprotocol/sdk`** in-process MCP server at `/mcp` — design-canvas tools, iOS build/control tools, and the export/preview tools.
- **A ~400-line SwiftUI preview host** ([preview-host/](preview-host/)) that renders the design natively on the simulator over `/ws/preview`.

## Getting started

Prereqs: Node 20+, a working C/C++ toolchain for `node-pty`'s prebuilds. For the iOS loop (live preview, Export & Run, simulator panel): macOS with Xcode.

```bash
npm install        # postinstall fixes node-pty perms
npm run dev        # tsx server.ts on :3000
```

Open http://localhost:3000. On first launch a blocking dialog asks you to pick a workspace directory — pick (or create) the folder you want the terminal agent to operate in. After that the right pane spawns a terminal there and runs the selected agent.

Other scripts:

```bash
npm run build      # next build (server stays the same)
npm start          # production server
npm test           # vitest run
npm run test:watch
```

If a fresh clone errors with `posix_spawnp failed`, run `node scripts/fix-node-pty.js` (the postinstall hook should already handle this).

## How it works

```
browser ──HTTP──►  Next request handler                                  ┐
browser ──HTTP──►  /mcp                StreamableHTTPServerTransport     │
browser ──HTTP──►  /api/ios/export-run → codegen + xcodebuild + launch   │── server.ts
browser ──HTTP──►  /api/preview/*      → preview-host lifecycle          │   (one Node process)
browser ──WS────►  /ws/terminal        → attachPty                       │
browser ──WS────►  /ws/ui-mock         → attachUIMock (spec cache)       │
simulator ─WS───►  /ws/preview         → attachPreview (resolved spec)   ┘
                            ↓                        ↓
                  node-pty.spawn($SHELL)      uiMockBridge cache
                  cwd: WORKSPACE_DIR          ⇄ .tango/design.json (persisted)
                  auto-runs selected agent    → previewBridge → simulator
```

Plus, on darwin, server boot spawns `npx serve-sim` once and the right-most panel iframes its preview UI.

- **Custom server** ([server.ts](server.ts)) hosts Next, three `WebSocketServer`s, and the MCP transport in one process. Required for `node-pty` and for the SDK's Node-typed transport — don't migrate to `next dev` or edge runtimes.
- **The design spec** (`UISpec`: screens of absolutely-positioned nodes) is the single source of truth. The browser canvas and the server cache sync over `/ws/ui-mock`; the cache persists (debounced, atomic) to `<workspace>/.tango/design.json` and hydrates back at boot, so restarts don't lose the canvas.
- **MCP tools** ([src/server/mcp.ts](src/server/mcp.ts)): design tools (`get_ui_mock`, `set_ui_mock`, `add_ui_screen`, node-level edits, `get_ui_layers`, `get_ui_viewport`), iOS tools (`ios_status`, `ios_build_run`, `ios_logs_recent`, plus `ios_inspect`/`ios_tap`/`ios_gesture`/`ios_type`/`ios_button`/`ios_rotate` to drive the running app), the loop tools (`export_run`, `preview_start`), and `remember_note` (workspace memory).
- **The style resolver** ([src/lib/uiResolve.ts](src/lib/uiResolve.ts)) flattens theme-token Tailwind + inline CSS into concrete RGBA/pixel values. It feeds **both** the SwiftUI codegen ([src/lib/specToSwiftUI.ts](src/lib/specToSwiftUI.ts)) and the preview-host wire protocol, so the two render paths can't drift and Swift never parses CSS.
- **Export & Run** writes `Tango<Name>Screen.swift` files (plus `TangoGeneratedRootView`) into `<source root>/TangoGenerated/`. Xcode 16 filesystem-synchronized projects pick the folder up automatically; older projects need a one-time drag into the target (surfaced as `manual-add-required`). Generated files carry a `tango:generated` marker — they're tango-owned and regenerated on every export.
- **The preview host** ([preview-host/](preview-host/)) builds once per machine into `~/.tango/preview-host-build`, then `simctl install`/`launch` with the port passed via `SIMCTL_CHILD_TANGO_WS_PORT`. The simulator shares the host's network stack, so it connects straight to `ws://localhost:<port>/ws/preview` and re-renders on every frame.
- **Simulator sidebar** ([src/server/sim.ts](src/server/sim.ts), darwin only) mirrors the booted iOS Simulator via `npx serve-sim` in a sandboxed iframe. Best-effort: if `xcrun` or the package isn't available, the panel surfaces the error and the rest of tango is unaffected.

## Workspace

Resolution order at boot ([src/server/workspace.ts](src/server/workspace.ts)):

1. `TANGO_WORKSPACE` env var — pinned, picker is read-only.
2. `~/.tango/state.json#lastWorkspace` — last-picked, if it still exists.
3. Unset — picker blocks the UI; the PTY refuses work until a workspace is chosen.

Picking a workspace is non-destructive. Tango manages these files in the chosen directory:

- `.claude/tango.md` — generated docs about the `tango-canvas` MCP tools and the design loop (overwritten).
- `.claude/skills/tango-*/SKILL.md` — Claude-facing workflow skills: `tango-ui-mock`, `tango-ui-import`, `tango-swiftui`, `tango-ios-sim` (overwritten).
- `.agents/skills/tango-*/SKILL.md` — Codex-facing mirrors of the same skills (overwritten).
- `.tango/bin/codex` — workspace-local Codex wrapper injected into tango terminal `PATH` (overwritten).
- `.tango/design.json` — the persisted design spec (committable; build junk in `.tango/` stays gitignored).
- `CLAUDE.md` — a 3-line sentinel block (`<!-- tango:start … -->`) is managed; everything outside is preserved byte-for-byte.
- `AGENTS.md` — a `<!-- tango-codex:start … -->` sentinel block is managed; everything outside is preserved byte-for-byte.
- `.mcp.json` — merged under `mcpServers['tango-canvas']`; refuses on malformed JSON.
- `.claude/settings.json` — merged to add `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.
- `tango-memory.md` — workspace memory (created if absent, never overwritten; notes fold deterministically).

You can switch workspace mid-session via the pill in the top bar; the terminal and canvas tear down and reopen against the new cwd (each workspace's design spec is restored from its own `design.json`).

You can switch the terminal agent from the top bar. Claude launches as `claude --dangerously-skip-permissions`; Codex launches with `gpt-5.5`, session-scoped `trust_level="trusted"` and `service_tier="fast"` overrides, the `tango-canvas` MCP URL, and bypassed approvals/sandbox flags for parity with the current Claude terminal flow. Tango also prepends `.tango/bin` to terminal `PATH`, so manually typing `codex` inside that terminal receives the same Tango MCP URL without editing global Codex config.

## Going deeper

[CLAUDE.md](CLAUDE.md) is the canonical architecture reference — it documents the wire protocols, the subtle invariants (why persistence captures `(workspace, spec)` at schedule time, why the codegen uses `.offset` instead of `.position`, why `transport.onclose` must not call `mcpServer.close()`, etc.), the design system, and the load-bearing test surfaces. Read it before changing anything in `src/server/` or the canvas components.

[preview-host/README.md](preview-host/README.md) documents the native preview app and its wire protocol.
