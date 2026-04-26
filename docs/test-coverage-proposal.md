# Test Coverage Analysis

## Current state

The repo has **zero tests and no test infrastructure**:

- No `jest`, `vitest`, `playwright`, or `node:test` config or dependency in [package.json](../package.json).
- `package.json` has no `test` script.
- No `*.test.*` / `*.spec.*` files anywhere in `src/` or the repo root.
- No `__tests__` / `tests/` directories.

The codebase has, however, accumulated a fair amount of subtle, regression-prone logic — most of it called out as "load-bearing" in [CLAUDE.md](../CLAUDE.md). This document proposes where to start, in priority order.

## Recommended toolchain

- **Unit/integration runner: `vitest`.** TS-native, ESM-clean, and works with `tsx`-style configs without a Babel/Jest transform layer. Co-locate `*.test.ts` next to the file under test.
- **DOM-touching components: `@testing-library/react` + `jsdom` env.** Only needed once we start covering React components; tier 1 below is all pure-Node.
- **No e2e for now.** The full stack (custom server + WS + `node-pty` + MCP transport + Excalidraw) is hard to drive end-to-end and brittle. Pay for that only after units cover the load-bearing logic.

## Tier 1 — load-bearing pure logic (start here)

Every item in this tier is a pure function or near-pure function. No fakes, no DOM, no WS — just inputs and outputs. The ROI/effort ratio is high and the invariants are explicitly documented in CLAUDE.md, so a regression here is a real bug.

### 1. `mergeClaudeMd` / `mergeMcpJson` / `mergeClaudeSettings` — [src/server/workspace.ts:460](../src/server/workspace.ts)

CLAUDE.md describes these as the "byte-for-byte preservation" merges. They have explicit refusal paths and idempotency requirements that are easy to break with a careless edit.

`mergeClaudeMd` — test cases:
- `null` / empty input → returns just the sentinel block with a trailing newline.
- Existing file already containing the sentinel block → first match replaced in place; trailing newlines preserved.
- Existing file with sentinel + arbitrary content above and below → only the sentinel region is rewritten; everything else is byte-identical.
- Existing file with no sentinel → block appended after a single blank line; pre-existing trailing whitespace normalised (no triple-blank-line).
- **Idempotency**: `mergeClaudeMd(mergeClaudeMd(x))` must equal `mergeClaudeMd(x)` for all `x`. Quick property test.
- Two sentinel blocks present (shouldn't happen, but defensive): only the first is replaced — current code intentionally targets the first match ([src/server/workspace.ts:456-458](../src/server/workspace.ts)). Lock that down.

`mergeMcpJson` — test cases:
- `null` / empty / whitespace-only input → returns `{ mcpServers: { 'tango-canvas': … } }` only.
- Malformed JSON → `{ ok: false, reason }` and **no mutation**.
- JSON that parses to an array / number / null → `{ ok: false }` (the `isPlainObject` guard at line 477).
- Existing file with other MCP servers → those are preserved verbatim.
- Existing file already containing `tango-canvas` with a stale port → port is rewritten.
- URL is built from `port` argument — verify `localhost:<port>` substitution.

`mergeClaudeSettings` — test cases:
- All the same shape-validation cases as `mergeMcpJson`.
- Existing `env` block preserved; `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` overlay added without dropping other keys.
- Hook configs / theme / model fields preserved at the top level.
- Existing `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0` → overwritten to `1` (current behaviour because of spread order at line 519).

### 2. `sanitizeAppState` — [src/lib/canvasBus.ts:21](../src/lib/canvasBus.ts)

CLAUDE.md flags this as the function whose failure crashes Excalidraw on `.forEach`. Test cases:
- `null` / `undefined` returned as-is.
- Non-object input returned as-is.
- `collaborators` / `pointers` / `followedBy` keys stripped regardless of value type.
- `width` / `height` / `offsetLeft` / `offsetTop` stripped (the stale-layout class).
- Any value that is `instanceof Map` or `instanceof Set` stripped, even at unexpected keys.
- Other keys preserved verbatim, including nested objects (which the function does **not** recurse into — lock down current shallow-only behaviour).

### 3. `recentProjects.add` / `recentProjects.remove` — [src/lib/recentProjects.ts](../src/lib/recentProjects.ts)

Use `vitest`'s `happy-dom` or stub `globalThis.localStorage`. Test cases:
- Empty list → add yields one entry.
- Adding a path that already exists → moved to head; length unchanged (MRU).
- Adding > 8 entries → list truncated to `MAX = 8` from the head.
- `remove` of a non-existent path → no-op, identical list.
- `read()` resilience: malformed JSON in `localStorage` → `[]`; non-array JSON → `[]`; entries missing `path`/`name` filtered.
- `write()` quota errors swallowed (assert no throw).

### 4. `parseFile` / `sliceBetween` / `formatEntry` / `countRecentEntries` — [src/server/memory.ts:124](../src/server/memory.ts)

This is the file Claude's session memory persists into; a corrupted parser silently destroys context across runs. Test cases:
- `parseFile` returns null for missing summary / recent / user fences (each branch at lines 152–156).
- Round-trip: `serialize(parseFile(x), iso) === x` for a well-formed input (modulo deterministic ISO).
- `sliceBetween` with `RegExp` start: matches the leftmost occurrence.
- `sliceBetween` returns null when end marker absent after a found start.
- `formatEntry` for each variant (`snapshot`, `agent_run`, `note`):
  - caption / goal / outcome longer than truncation threshold → ends with `…`, total length ≤ N.
  - `oneLine` collapses internal whitespace.
  - `agent_run` with no tools → `"no tools"` literal; missing outcome → `—`.
- `countRecentEntries` only counts lines starting with `- `, ignoring headings and blank lines.
- `rescueMalformed` wraps a non-empty existing string into the user-notes block — verify the original content appears verbatim inside, and the canonical fences exist around it.

### 5. `lastUserGoal` / `mcpUrl` — [src/app/api/agent/route.ts:50](../src/app/api/agent/route.ts)

- `lastUserGoal`: empty messages → `''`; only assistant messages → `''`; user messages with no text parts → falls through to next-newer; multiple text parts joined by space; trims.
- `mcpUrl`: derives `<proto>//<host>/mcp` from a `Request` URL — checks for `http`, `https`, custom port, IPv6 host. Lock it down so we don't regress to a hardcoded `localhost:3000`.
- The `ALLOWED_TOOLS` filter (line 99) — pull it into a tiny pure helper `filterAllowedTools(allTools, allowed)` and unit-test that canvas tools (`set_canvas_state`, `add_elements`, etc.) are dropped while UI/terminal tools survive. Today the filter is inline; pulling it out is a 3-line refactor that pays for itself the moment someone renames a tool.

### 6. `validatePath` — [src/server/workspaceState.ts:69](../src/server/workspaceState.ts)

Boundary cases that a careless refactor could break:
- Empty string → rejected.
- Tilde expansion (`~/foo` → `$HOME/foo`).
- Relative path → rejected (must be absolute).
- `'/'` and `os.homedir()` → rejected (the explicit guard at lines 82–86).
- Path that doesn't exist → rejected with a stat-based reason.
- Path that's a file, not a directory → rejected.
- Path missing R/W permission → rejected. (Use `fs.chmod` on a tmpdir to create the case; skip on platforms where that's flaky.)

## Tier 2 — node-only logic with light I/O

These are worth covering once Tier 1 lands. They have side effects (filesystem, in-memory pubsub) but the boundary is small enough to fake.

### 7. `ensureWorkspace` — [src/server/workspace.ts:550](../src/server/workspace.ts)

Drive against an `os.tmpdir()` workspace and assert:
- Fresh empty dir → all five managed paths created (`.claude/tango.md`, `CLAUDE.md`, `.mcp.json`, `.claude/settings.json`, `design-scratch/`) plus the two skill dirs.
- Pre-existing valid `CLAUDE.md` with user content → user content preserved byte-for-byte; sentinel block added.
- Pre-existing malformed `.mcp.json` → `{ ok: false, errors: [{ file: '.mcp.json', reason }] }`; the file on disk is **not** rewritten; other managed files still get written (the soft-error contract documented in CLAUDE.md).
- Same for malformed `.claude/settings.json`.
- Second invocation against the same workspace → `writeIfChanged` short-circuits; `mtime`s of unchanged files are preserved (or assert that the file content is byte-identical after two runs).

### 8. `createPendingMap` / `createHub` — [src/server/wsHub.ts](../src/server/wsHub.ts)

This is the request/reply correlation engine behind `screenshot_canvas` and `dom_inspect`. Failures here look like "the agent silently hangs". Test cases:
- `register()` → `requestId` is unique across calls.
- Resolve before timeout → promise resolves; subsequent `resolve(id, …)` is a no-op.
- Timeout fires → promise rejects with the configured reason; subsequent resolve is a no-op.
- `cancelAll(reason)` rejects every in-flight promise.
- `pickOpen` returns only sockets in `OPEN` state — pass a `{ readyState }`-shaped fake.
- `broadcast` continues iterating after a `send` throw on one socket.
- Bad JSON inbound → no throw, no listener invocation.

### 9. `canvasBridge` — [src/server/canvasBridge.ts](../src/server/canvasBridge.ts)

- Snapshot inbound from a fake WS → cache mutated; subsequent `getSnapshot()` reflects it.
- `requestScreenshot` with no open socket → rejects fast (no timeout wait).
- `requestScreenshot` with a fake socket that replies with `{ requestId, mime, data }` → resolves with that payload.
- Reply with mismatched `requestId` → ignored; original promise still pending until timeout.
- Reply missing `mime` or `data` → reject with explanatory error.

### 10. `agentCursorBridge` — [src/server/agentCursorBridge.ts](../src/server/agentCursorBridge.ts)

Same shape as canvasBridge; share fixtures.
- `pushCursorCommand` returns `0` when no sockets open.
- `pushCursorCommand` returns delivered count even when half the sockets throw on `send`.
- `requestInspect` round-trip mirrors `requestScreenshot`.

### 11. Route input validation

All four routes are short and validation-heavy:
- [src/app/api/design/snapshot/route.ts](../src/app/api/design/snapshot/route.ts): no workspace → 409; oversized caption → truncated to 240 chars; empty body → 400; ISO timestamp + random hex filename collision-free over 1000 calls.
- [src/app/api/workspace/select/route.ts](../src/app/api/workspace/select/route.ts): missing path → 400; non-string path → 400; `dryRun: true` does not call `setWorkspace`.
- [src/app/api/workspace/browse/route.ts](../src/app/api/workspace/browse/route.ts): unsupported platform → structured error; `__CANCELLED__` sentinel from `osascript` returned as `{ canceled: true }`; trailing-slash strip on the picked path. The `osascript` `spawn` call needs a fake `child_process.spawn`.

## Tier 3 — UI components (lower priority)

Component tests are higher cost (jsdom + RTL + Excalidraw and xterm both refuse SSR / jsdom in subtle ways) and the parts most worth covering are simple enough that a smoke-render plus a couple of behaviour assertions will do.

Worth covering eventually:
- `WorkspaceDialog` — recent-list rendering, env-locked read-only mode, soft-warning surface.
- `AgentTrigger` — submitting kicks off a `useChat` request; log-panel renders streamed messages.
- `AgentCursorOverlay` — `dom_inspect` walker actually finds elements behind a `data-agent-cursor` filter.

Skip for now (high cost, low ROI):
- `Terminal` (xterm.js needs a real DOM with sizing).
- `DesignerCanvas` (Excalidraw module-load `window` access).
- Anything in `src/components/ui/` (radix-ui passthrough).

## Tier 4 — explicitly out of scope

- The PTY bridge ([src/server/pty.ts](../src/server/pty.ts)). Would require a `node-pty` fake; the binary surface is small and hand-tested every dev session.
- The MCP transport wiring in [src/server/mcp.ts](../src/server/mcp.ts) below the tool-handler level. Tool handlers are testable; the SDK's `StreamableHTTPServerTransport` plumbing isn't worth re-implementing in tests.
- The custom server `'upgrade'` routing in [server.ts](../server.ts). End-to-end smoke test once we have an e2e harness; until then it's hand-tested.

## Suggested execution order

1. Add `vitest` + a `test` script in [package.json](../package.json). One config file, one CI command.
2. **Tier 1** in one PR per item, in the order listed (workspace merges → sanitizeAppState → recentProjects → memory parsing → agent helpers → validatePath). All pure-Node; no jsdom yet.
3. **Tier 2** once Tier 1 is green; introduce the tmpdir + fake-WS fixtures here.
4. Add `jsdom` env and **Tier 3** only when there's appetite for component coverage.

Each Tier 1 item is small enough to land in a single PR with ~30–80 lines of test code. The whole tier is a couple of days of work and would catch the categories of regression CLAUDE.md keeps warning future-Claude about.
