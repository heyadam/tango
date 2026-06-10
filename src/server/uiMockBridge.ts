import type { WebSocket } from 'ws';
import { registerHook } from './serverHooks';
import { createHub } from './wsHub';
import { getWorkspaceOrNull } from './workspace';
import { broadcastPreviewSpec, broadcastShowScreen } from './previewBridge';
import {
  flushPendingPersist,
  loadSpecFromDisk,
  schedulePersist,
} from './uiMockPersist';
import {
  EMPTY_SPEC,
  type UIMockClientMsg,
  type UIMockServerMsg,
  type UIScreen,
  type UISpec,
} from '@/lib/uiMockProtocol';
import {
  addNodesToScreen,
  appendScreenToSpec,
  removeNodesFromSpec,
  removeScreenFromSpec,
  reorderNodeInSpec,
  updateNodeInSpec,
  type NodePatch,
  type ReorderOp,
} from '@/lib/uiMockOps';
import type { UINode } from '@/lib/uiMockProtocol';

// Authoritative server-side cache of the design spec ("UI mock"). The
// browser is the source of truth for
// human edits (drag/resize/text snapshots ship up the WS); MCP tools are the
// source of truth for AI edits (set/append helpers below). Last-writer-wins.
// The cache is persisted write-behind to <workspace>/.tango/design.json (see
// uiMockPersist) and hydrated back at boot / workspace switch.

let cache: UISpec = EMPTY_SPEC;
// Live pixel size of the browser's UI panel render area, pushed up the WS by
// UIPanel on mount + debounced resize. Surfaced to Claude via `get_ui_viewport`
// so new screens default to "what the user actually sees" instead of a
// hardcoded form-factor size. `null` until the first browser connects.
let viewport: { w: number; h: number } | null = null;
// Which screen the user is working in (last selected node's screen / last
// clicked frame). The preview-host app shows this screen on the simulator.
// Defaults to the first screen whenever the current id stops existing.
let activeScreenId: string | null = null;

const hub = createHub();

// Cleared by setWorkspace via the cross-context registry (route handlers live
// in a different module graph; see serverHooks.ts). The workspace slot has
// already been swung to the NEW workspace by the time this runs, so flush
// (which writes pending specs to the workspaces captured at schedule time)
// must come first, then hydrate reads the new workspace's file.
registerHook('resetUiMock', () => {
  flushPendingPersist();
  cache = { screens: [] };
  viewport = null;
  activeScreenId = null;
  broadcast({ type: 'set', spec: cache });
  broadcastPreviewSpec(cache, activeScreenId);
  void hydrateUIMockFromDisk();
});

// Route-handler-graph readers (Export & Run, preview status) reach the live
// cache through the globalThis hook registry.
registerHook('getUiMockSpec', () => cache);
registerHook('getUiMockActiveScreen', () => activeScreenId);
// Route-handler-graph writer (the fast import engine) — full broadcast
// semantics, same as an MCP set_ui_mock.
registerHook('setUiMockSpec', (spec) => setUIMockFromServer(spec));

function broadcast(msg: UIMockServerMsg): void {
  hub.broadcast(msg);
}

// Keep activeScreenId pointing at a real screen: default to the first screen
// when unset or stale.
function reconcileActiveScreen(): void {
  if (cache.screens.length === 0) {
    activeScreenId = null;
    return;
  }
  if (!activeScreenId || !cache.screens.some((s) => s.id === activeScreenId)) {
    activeScreenId = cache.screens[0].id;
  }
}

// Single choke point for "the cache changed": optionally broadcast to
// browsers, always mirror to the preview host, and always schedule the
// write-behind persist. The browser snapshot path persists + previews without
// re-broadcasting to browsers (last-writer-wins semantics, unchanged).
function cacheChanged(broadcastMsg?: UIMockServerMsg): void {
  if (broadcastMsg) broadcast(broadcastMsg);
  reconcileActiveScreen();
  broadcastPreviewSpec(cache, activeScreenId);
  const ws = getWorkspaceOrNull();
  if (ws) schedulePersist(ws, cache);
}

// Load the active workspace's persisted spec into the cache and tell every
// connected browser. No-op when there's no workspace or no (valid) file.
// Does NOT schedule a persist — hydration must not rewrite its own source.
export async function hydrateUIMockFromDisk(): Promise<void> {
  const ws = getWorkspaceOrNull();
  if (!ws) return;
  const spec = await loadSpecFromDisk(ws);
  if (!spec) return;
  // A switch could have raced the read; only apply if we're still on the
  // workspace we read from.
  if (getWorkspaceOrNull() !== ws) return;
  cache = spec;
  broadcast({ type: 'set', spec });
  reconcileActiveScreen();
  broadcastPreviewSpec(cache, activeScreenId);
}

export function attachUIMock(ws: WebSocket): void {
  hub.attach(ws, {
    onMessage: (raw) => {
      const parsed = raw as UIMockClientMsg;
      if (parsed.type === 'snapshot' && parsed.spec) {
        cache = parsed.spec;
        cacheChanged();
      } else if (parsed.type === 'viewport') {
        const w = Math.round(parsed.w);
        const h = Math.round(parsed.h);
        if (Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0) {
          viewport = { w, h };
        }
      } else if (parsed.type === 'active_screen') {
        const id = parsed.screenId;
        if (
          typeof id === 'string' &&
          id !== activeScreenId &&
          cache.screens.some((s) => s.id === id)
        ) {
          activeScreenId = id;
          broadcastShowScreen(id);
        }
      }
    },
  });

  // Send the current cache so a fresh client sees what AI has already written,
  // even if no other browser is open. The browser's own snapshot a moment
  // later will overwrite this with its localStorage-backed spec — fine, user
  // state wins on tie.
  try {
    ws.send(
      JSON.stringify({ type: 'set', spec: cache } satisfies UIMockServerMsg),
    );
  } catch {
    // socket already gone
  }
}

export function getUIMock(): UISpec {
  return cache;
}

export function getUIViewport(): { w: number; h: number } | null {
  return viewport;
}

export function setUIMockFromServer(spec: UISpec): void {
  cache = spec;
  cacheChanged({ type: 'set', spec });
}

// Validated append (duplicate screen id, intra-screen node dupes, global
// node-id collisions) — throws to the MCP handler's toolErrorResult so
// add_ui_screen fails loudly instead of corrupting the spec.
export function appendUIScreenFromServer(screen: UIScreen): void {
  cache = appendScreenToSpec(cache, screen);
  cacheChanged({ type: 'append_screen', screen });
}

export function removeUIScreenFromServer(screenId: string): void {
  setUIMockFromServer(removeScreenFromSpec(cache, screenId));
}

export function clearUIMockFromServer(): void {
  setUIMockFromServer({ screens: [] });
}

// ── Node-level mutations ────────────────────────────────────────────────────
// Each applies a pure op from uiMockOps to the LIVE cache (which reflects the
// user's latest drag/resize/text snapshot) and re-broadcasts the whole spec
// via setUIMockFromServer. Operating on the live cache — not a Claude-supplied
// spec — is what preserves the user's tweaks to every other node. The ops
// throw on bad input (unknown ids, collisions); MCP handlers surface that.

export function addUINodesFromServer(screenId: string, nodes: UINode[]): void {
  setUIMockFromServer(addNodesToScreen(cache, screenId, nodes));
}

export function updateUINodeFromServer(nodeId: string, patch: NodePatch): void {
  setUIMockFromServer(updateNodeInSpec(cache, nodeId, patch));
}

export function removeUINodesFromServer(nodeIds: string[]): void {
  setUIMockFromServer(removeNodesFromSpec(cache, nodeIds));
}

export function reorderUINodeFromServer(nodeId: string, op: ReorderOp): void {
  setUIMockFromServer(reorderNodeInSpec(cache, nodeId, op));
}
