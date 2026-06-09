# tango

A split-pane web app for collaborating with terminal-based coding agents. The left pane is an Excalidraw canvas (and other UI surfaces, over time); the right pane is a real interactive terminal running the selected agent (`claude` by default, switchable to `codex`) in your chosen workspace. An optional further-right sidebar mirrors a booted iOS Simulator via [serve-sim](https://github.com/EvanBacon/serve-sim) for tight feedback while building mobile UI. An in-process MCP server gives the active terminal agent tools to read and write the canvas, and a small gpt-5.5 controller agent in the toolbar can drive the visible UI on your behalf — moving the cursor, clicking buttons, and dispatching work to the active terminal agent.

The repo is **tango itself**. The directory tango operates on (where the terminal agent's shell runs, where snapshots get written) is a separate workspace you pick from the in-app picker on first launch.

## Stack

- **Next.js 16** (App Router) on a **custom Node server** — `next dev` is not used; the WebSocket bridge and MCP transport live in-process.
- **React 19** + **Tailwind v4** + a shadcn-style primitive layer in [src/components/ui/](src/components/ui/).
- **node-pty** for the terminal, bridged over `/ws/terminal`.
- **Excalidraw** for the canvas, bridged over `/ws/canvas`.
- **`@modelcontextprotocol/sdk`** in-process MCP server at `/mcp`, exposing canvas tools and agent UI tools.
- **Vercel AI SDK v6** + **`@ai-sdk/mcp`** controller agent at `/api/agent`, driving an `AgentCursorOverlay` over `/ws/agent-cursor`.

## Getting started

Prereqs: Node 20+, a working C/C++ toolchain for `node-pty`'s prebuilds, and an `OPENAI_API_KEY` in `.env.local` if you want to use the controller agent.

```bash
npm install        # postinstall fixes node-pty perms + symlinks .env.local
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
browser ──HTTP──►  Next request handler                                 ┐
browser ──HTTP──►  /mcp        StreamableHTTPServerTransport            │
browser ──HTTP──►  /api/agent  streamText + @ai-sdk/mcp client          │── server.ts
browser ──HTTP──►  /api/sim/status  → getSimStatus()                    │
browser ──WS────►  /ws/terminal      → attachPty                        │
browser ──WS────►  /ws/canvas        → attachCanvas                     │
browser ──WS────►  /ws/agent-cursor  → attachAgentCursor                ┘
                                ↓                       ↓                   ↓
                          node-pty.spawn($SHELL)    scene cache         McpServer + tools
                          cwd: WORKSPACE_DIR        (canvasBridge)      (canvas + agent UI tools)
                          auto-runs selected agent
```

Plus, on darwin, server boot also spawns `npx serve-sim` once and the right-most panel iframes its preview UI.

- **Custom server** ([server.ts](server.ts)) hosts Next, three `WebSocketServer`s, and the MCP transport in one process. Required for `node-pty` and for the SDK's Node-typed transport — don't migrate to `next dev` or edge runtimes.
- **MCP tools** ([src/server/mcp.ts](src/server/mcp.ts)) split into *canvas* (`get_canvas_state`, `set_canvas_state`, `add_elements`, `clear_canvas`, `screenshot_canvas`) and *agent UI* (`dom_inspect`, `cursor_move`, `cursor_click`, `cursor_type`, `terminal_type`). The active terminal agent sees all of them; the controller agent sees only the agent UI subset (it's a controller, not the brain — it delegates creative work back into the terminal via `terminal_type`).
- **Designer canvas** is duplex: Excalidraw changes snapshot to the server every 500ms, and MCP tool writes broadcast back to all connected browsers as scene patches.
- **Simulator sidebar** ([src/server/sim.ts](src/server/sim.ts), darwin only) mirrors a booted iOS Simulator. Server boot spawns `npx serve-sim`, parses the preview URL from its stdout, and the right-most aside iframes that URL inside a sandboxed frame. Best-effort: if `xcrun` or the package isn't available, the panel surfaces the error and the rest of tango is unaffected.

## Workspace

Resolution order at boot ([src/server/workspace.ts](src/server/workspace.ts)):

1. `TANGO_WORKSPACE` env var — pinned, picker is read-only.
2. `~/.tango/state.json#lastWorkspace` — last-picked, if it still exists.
3. Unset — picker blocks the UI; PTY and snapshot routes refuse work until a workspace is chosen.

Picking a workspace is non-destructive. Tango manages these files in the chosen directory:

- `.claude/tango.md` — generated docs about the `tango-canvas` MCP tools (overwritten).
- `.claude/skills/tango-*/SKILL.md` — Claude-facing Tango workflow skills (overwritten).
- `.agents/skills/tango-*/SKILL.md` — Codex-facing Tango workflow skills (overwritten).
- `.tango/bin/codex` — workspace-local Codex wrapper injected into Tango terminal `PATH` (overwritten).
- `CLAUDE.md` — a 3-line sentinel block (`<!-- tango:start … -->`) is managed; everything outside is preserved byte-for-byte.
- `AGENTS.md` — a `<!-- tango-codex:start … -->` sentinel block is managed; everything outside is preserved byte-for-byte.
- `.mcp.json` — merged under `mcpServers['tango-canvas']`; refuses on malformed JSON.
- `.claude/settings.json` — merged to add `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.
- `design-scratch/` — `mkdir -p`. PNGs from the canvas's send-to-agent button land here.

You can switch workspace mid-session via the pill in the top bar; the terminal and canvas tear down and reopen against the new cwd.

You can switch the terminal agent from the top bar. Claude launches as `claude --dangerously-skip-permissions`; Codex launches with `gpt-5.5`, session-scoped `trust_level="trusted"` and `service_tier="fast"` overrides, the `tango-canvas` MCP URL, and bypassed approvals/sandbox flags for parity with the current Claude terminal flow. Tango also prepends `.tango/bin` to terminal `PATH`, so manually typing `codex` inside that terminal receives the same Tango MCP URL without editing global Codex config.

## Going deeper

[CLAUDE.md](CLAUDE.md) is the canonical architecture reference — it documents the wire protocols, the subtle invariants (why `terminal_type` writes text and `\r` as separate writes, why `transport.onclose` must not call `mcpServer.close()`, why appState needs sanitizing on every JSON boundary, etc.), the design system, and the load-bearing test surfaces. Read it before changing anything in `src/server/` or `src/components/Terminal.tsx`, `SketchPanel.tsx`, `DesignerCanvas.tsx`, or `AgentCursorOverlay.tsx`.

[docs/test-coverage-proposal.md](docs/test-coverage-proposal.md) tracks the test gaps and a tiered plan for closing them.
