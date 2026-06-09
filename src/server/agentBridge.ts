// Built-in agent bridge: one Claude Agent SDK session per /ws/agent
// connection, replacing the PTY+CLI pair for the 'tango' terminal agent. The
// SDK runs the Claude Code engine headless (a managed subprocess — no PTY, no
// xterm); we pipe user messages in via a streaming-input queue and translate
// the SDK's structured messages to the small wire protocol in
// src/lib/agentProtocol.ts.
//
// Tool surface: the existing in-process MCP server over localhost HTTP
// (/mcp) — the same seam every other agent uses, so capabilities can't
// drift between the built-in agent and external CLIs. Skills come from the
// workspace's .claude/skills (installed by ensureWorkspace), discovered by
// the engine itself.

import type { WebSocket } from 'ws';
import {
  query,
  startup,
  type Options,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
  type WarmQuery,
} from '@anthropic-ai/claude-agent-sdk';
import type { AgentClientMsg, AgentServerMsg } from '@/lib/agentProtocol';
import { summarizeToolInput, displayToolName } from '@/lib/agentProtocol';
import { getWorkspaceOrNull } from './workspace';
import {
  getTerminalAgent,
  loadPersistedAgentSession,
  persistAgentSession,
} from './workspaceState';
import { registerHook } from './serverHooks';
import { terminalAgentMcpUrl } from './terminalAgent';
import { createHub } from './wsHub';

const hub = createHub();

registerHook('agentBroadcastWorkspaceChanged', () => {
  discardWarm();
  hub.broadcast({ type: 'workspace_changed' } satisfies AgentServerMsg);
  warmAgentEngine();
});

registerHook('agentBroadcastTerminalAgentChanged', () => {
  hub.broadcast({
    type: 'terminal_agent_changed',
    agent: getTerminalAgent(),
  } satisfies AgentServerMsg);
  warmAgentEngine();
});

// Tango-specific instructions appended to the Claude Code preset prompt. The
// workspace's CLAUDE.md (which @-includes .claude/tango.md) is loaded by the
// preset as usual, so this stays short: panel context + response shape.
const TANGO_SYSTEM_APPEND = [
  "You are tango's built-in agent, embedded in a chat panel beside the design canvas (no terminal — your text renders as chat).",
  "The tango-canvas MCP tools drive the canvas, the live preview, and the iOS simulator; the workspace's .claude/tango.md and the tango-* skills document the loop — reach for those tools whenever the user talks about the design, the canvas, screens, the preview, or the simulator.",
  'The canvas changes outside this conversation — the user drags/edits nodes directly and tango imports screens on its own — so never trust your memory of the spec: call get_ui_mock (or get_ui_layers) before describing or editing what is on the canvas.',
  'Keep responses tight: a sentence or two between tool calls, a short summary at the end. The user is watching the canvas and simulator, not reading reports.',
].join(' ');

function serverPort(): number {
  const raw = Number(process.env.TANGO_PORT ?? process.env.PORT ?? 3000);
  return Number.isFinite(raw) && raw > 0 ? raw : 3000;
}

async function buildOptions(workspace: string): Promise<Options> {
  const resume =
    (await loadPersistedAgentSession(workspace).catch(() => null)) ??
    undefined;
  return {
    cwd: workspace,
    resume,
    mcpServers: {
      'tango-canvas': {
        type: 'http',
        url: terminalAgentMcpUrl(serverPort()),
        // The canvas/iOS tools ARE the product surface — always in the
        // prompt, never deferred behind tool search (saves a ToolSearch hop
        // before the first canvas edit of a session).
        alwaysLoad: true,
      },
    },
    systemPrompt: {
      type: 'preset',
      preset: 'claude_code',
      append: TANGO_SYSTEM_APPEND,
    },
    // Same trust level the PTY agents run with (claude
    // --dangerously-skip-permissions / codex --dangerously-bypass-…).
    permissionMode: 'bypassPermissions',
    allowDangerouslySkipPermissions: true,
    skills: 'all',
    includePartialMessages: true,
    // Sonnet 4.6 by default: the interactive loop favors speed and cost over
    // peak capability. Override per-machine with TANGO_AGENT_MODEL.
    model: process.env.TANGO_AGENT_MODEL ?? 'claude-sonnet-4-6',
  };
}

// ── Warm spare ──────────────────────────────────────────────────────────────
// The engine subprocess takes seconds to boot; pre-warm one per workspace so
// the first user message doesn't pay it. Discarded on workspace switch (its
// cwd and resume target are stale) and re-warmed after every claim.

type WarmSlot = {
  promise: Promise<WarmQuery> | null;
  workspace: string | null;
};

const warmSlot: WarmSlot = { promise: null, workspace: null };

function discardWarm(): void {
  const prev = warmSlot.promise;
  warmSlot.promise = null;
  warmSlot.workspace = null;
  if (prev) {
    prev.then((w) => w.close()).catch(() => {});
  }
}

// Pre-warm an engine for the current workspace. No-op unless the built-in
// agent is selected and a workspace is set. Safe to call repeatedly.
export function warmAgentEngine(): void {
  if (process.env.TANGO_AGENT_NO_PREWARM === '1') return;
  const workspace = getWorkspaceOrNull();
  if (!workspace || getTerminalAgent() !== 'tango') return;
  if (warmSlot.promise && warmSlot.workspace === workspace) return;
  discardWarm();
  warmSlot.workspace = workspace;
  warmSlot.promise = (async () => {
    const options = await buildOptions(workspace);
    return startup({ options });
  })();
  warmSlot.promise.catch((err) => {
    console.warn('[agent] pre-warm failed', err);
    if (warmSlot.workspace === workspace) {
      warmSlot.promise = null;
      warmSlot.workspace = null;
    }
  });
}

async function claimWarm(workspace: string): Promise<WarmQuery | null> {
  if (!warmSlot.promise || warmSlot.workspace !== workspace) return null;
  const promise = warmSlot.promise;
  warmSlot.promise = null;
  warmSlot.workspace = null;
  try {
    return await promise;
  } catch {
    return null;
  }
}

// ── Streaming-input queue ───────────────────────────────────────────────────

type InputQueue = {
  iterable: AsyncIterable<SDKUserMessage>;
  push: (m: SDKUserMessage) => void;
  end: () => void;
};

function createInputQueue(): InputQueue {
  const buffer: SDKUserMessage[] = [];
  let notify: (() => void) | null = null;
  let ended = false;
  const wake = () => {
    const n = notify;
    notify = null;
    n?.();
  };
  return {
    push(m) {
      if (ended) return;
      buffer.push(m);
      wake();
    },
    end() {
      ended = true;
      wake();
    },
    iterable: {
      async *[Symbol.asyncIterator]() {
        for (;;) {
          while (buffer.length > 0) yield buffer.shift() as SDKUserMessage;
          if (ended) return;
          await new Promise<void>((resolve) => {
            notify = resolve;
          });
        }
      },
    },
  };
}

function userMessage(text: string): SDKUserMessage {
  return {
    type: 'user',
    message: { role: 'user', content: [{ type: 'text', text }] },
    parent_tool_use_id: null,
  };
}

// ── Connection handling ─────────────────────────────────────────────────────

export function attachAgent(ws: WebSocket): void {
  const workspace = getWorkspaceOrNull();
  if (workspace == null) {
    try {
      ws.close(4001, 'no workspace selected');
    } catch {
      // already closed
    }
    return;
  }

  hub.attach(ws, {
    onMessage: (parsed) => {
      const msg = parsed as AgentClientMsg;
      if (msg.type === 'user_message' && typeof msg.text === 'string') {
        const text = msg.text.trim();
        if (text.length > 0) input.push(userMessage(text));
        return;
      }
      if (msg.type === 'interrupt') {
        activeQuery?.interrupt().catch(() => {});
      }
    },
  });

  const send = (msg: AgentServerMsg): void => {
    try {
      ws.send(JSON.stringify(msg));
    } catch {
      // socket dying — cleanup runs on close
    }
  };

  const input = createInputQueue();
  let activeQuery: Query | null = null;
  let closed = false;

  // Per-connection stream state: content-block index → block type, so
  // content_block_stop can tell a text block from a tool_use block.
  const blockTypes = new Map<number, string>();

  const handleMessage = (msg: SDKMessage): void => {
    switch (msg.type) {
      case 'system': {
        if (msg.subtype === 'init') {
          send({ type: 'ready', sessionId: msg.session_id, model: msg.model });
          void persistAgentSession(workspace, msg.session_id).catch(() => {});
        } else if (msg.subtype === 'status' && msg.status === 'compacting') {
          send({ type: 'status', text: 'Compacting conversation…' });
        }
        return;
      }
      case 'stream_event': {
        if (msg.parent_tool_use_id) return;
        const ev = msg.event;
        if (ev.type === 'content_block_start') {
          blockTypes.set(ev.index, ev.content_block.type);
          return;
        }
        if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') {
          send({ type: 'text_delta', text: ev.delta.text });
          return;
        }
        if (
          ev.type === 'content_block_stop' &&
          blockTypes.get(ev.index) === 'text'
        ) {
          send({ type: 'text_done' });
        }
        return;
      }
      case 'assistant': {
        if (msg.parent_tool_use_id) return;
        if (msg.error) {
          send({ type: 'error', message: `model error: ${msg.error}` });
        }
        for (const block of msg.message.content) {
          if (block.type === 'tool_use') {
            send({
              type: 'tool_use',
              name: displayToolName(block.name),
              detail: summarizeToolInput(block.name, block.input),
            });
          }
        }
        return;
      }
      case 'result': {
        // SDKResultError carries the underlying failure detail in `errors` —
        // surface it, a bare subtype ("error during execution") is undebuggable.
        const detail =
          msg.subtype !== 'success' && Array.isArray(msg.errors)
            ? msg.errors.filter(Boolean).join('; ').slice(0, 500)
            : '';
        if (msg.subtype !== 'success') {
          console.warn('[agent] turn failed:', msg.subtype, detail);
        }
        send({
          type: 'turn_done',
          ok: msg.subtype === 'success' && !msg.is_error,
          durationMs: msg.duration_ms,
          costUsd: msg.total_cost_usd,
          ...(msg.subtype !== 'success'
            ? {
                error: detail
                  ? `${msg.subtype.replace(/_/g, ' ')}: ${detail}`
                  : msg.subtype.replace(/_/g, ' '),
              }
            : {}),
        });
        return;
      }
      default:
        return;
    }
  };

  void (async () => {
    try {
      const warm = await claimWarm(workspace);
      if (!warm) send({ type: 'status', text: 'Starting agent engine…' });
      const q = warm
        ? warm.query(input.iterable)
        : query({
            prompt: input.iterable,
            options: await buildOptions(workspace),
          });
      activeQuery = q;
      // Replace the spare we just consumed (or start one for next time).
      warmAgentEngine();
      if (closed) {
        // Socket died while the engine was claiming/booting.
        input.end();
        void q.interrupt().catch(() => {});
        return;
      }
      for await (const message of q) {
        if (closed) break;
        handleMessage(message);
      }
    } catch (err) {
      if (!closed) {
        send({
          type: 'error',
          message: `agent engine failed: ${err instanceof Error ? err.message : String(err)}`,
        });
        try {
          ws.close(1011, 'agent engine failed');
        } catch {
          // already closed
        }
      }
    }
  })();

  const cleanup = () => {
    if (closed) return;
    closed = true;
    input.end();
    activeQuery?.interrupt().catch(() => {});
  };

  ws.on('close', cleanup);
  ws.on('error', cleanup);
}
