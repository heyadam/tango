// In-process MCP server. Mounted on the bare http.createServer in server.ts —
// NOT under app/api/.../route.ts, because the Streamable HTTP transport wants
// Node IncomingMessage/ServerResponse, not Web Fetch Request/Response.
//
// Tools live alongside uiMockBridge in the same Node process so they can read
// and write the design-spec cache without IPC. The browser is told about spec
// changes via the /ws/ui-mock bridge.

import { randomUUID } from 'node:crypto';
import type http from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import * as z from 'zod/v4';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import {
  addUINodesFromServer,
  appendUIScreenFromServer,
  clearUIMockFromServer,
  duplicateUIScreenFromServer,
  getUIMock,
  getUIViewport,
  groupUINodesFromServer,
  removeUINodesFromServer,
  removeUIScreenFromServer,
  renameUIGroupFromServer,
  reorderUINodeFromServer,
  setUIMockFromServer,
  ungroupUINodesFromServer,
  updateUINodeFromServer,
  updateUINodesFromServer,
  updateUIScreenFromServer,
} from './uiMockBridge';
import { describeLayers } from '@/lib/uiMockOps';
import type { UINode, UIScreen, UISpec } from '@/lib/uiMockProtocol';
import {
  uiNodePatchSchema,
  uiNodeSchema,
  uiScreenSchema,
  uiSpecSchema,
} from '@/lib/uiMockSchema';
import { recordNote } from './memory';
import { resolveBuildProject, runExportAndRun } from './iosExport';
import { getPreviewHostStatus, startPreviewHost } from './previewHost';
import { getIosProject, getWorkspaceOrNull } from './workspace';
import {
  iosBuildRun,
  iosLogsRecent,
  isSafeUdid,
  listBootedDevices,
  readActiveDeviceFromServeSim,
  resolveActiveUdid,
} from './iosBuild';
import { tangoPort } from './config';
import {
  type ControlResult,
  fetchAxSnapshot,
  iosButton,
  iosGesture,
  iosRotate,
  iosTap,
  iosType,
  isValidButtonName,
  isValidOrientation,
  ROTATE_ORIENTATIONS,
  toInspectResult,
  validateNormalized,
} from './iosSimControl';
import { getSimStatus } from './sim';

// UISpec zod schemas live in src/lib/uiMockSchema.ts (shared with the
// design-file persistence validator).

// z-order operations for `reorder_ui_node`. front/back jump to top/bottom of
// the screen's stack; forward/backward swap with the adjacent sibling.
const reorderOpEnum = z.enum(['front', 'back', 'forward', 'backward']);

const TANGO_MCP_INSTRUCTIONS =
  'Tango is a split-pane app: the user sees a direct-manipulation design canvas on the left (a spec of screens with absolutely-positioned nodes — the "UI mock") and this terminal agent on the right. Use get_ui_viewport/get_ui_mock before proposing designs, then set_ui_mock/add_ui_screen for fresh work and add_ui_nodes/update_ui_node/remove_ui_node/reorder_ui_node for incremental edits that preserve the user\'s manual tweaks. Use ios_status and ios_build_run after Swift edits when an iOS project is detected, and the ios_* control tools to drive the running app.';

function toolErrorResult(toolName: string, err: unknown) {
  return {
    isError: true,
    content: [
      {
        type: 'text' as const,
        text: `${toolName} failed: ${err instanceof Error ? err.message : String(err)}`,
      },
    ],
  };
}

// Shared shape for `ios_build_run` early-exit errors — keeps the result
// schema consistent with the orchestrator's own `{ok:false, stage, message,
// errors}` returns so the terminal agent does not have to parse two formats.
function iosBuildErrorResult(
  stage: 'detect' | 'build' | 'install' | 'launch',
  message: string,
) {
  return {
    content: [
      {
        type: 'text' as const,
        text: JSON.stringify(
          { ok: false, stage, message, errors: [] as string[] },
          null,
          2,
        ),
      },
    ],
  };
}

// Shared preflight for the `ios_*` simulator-control tools: serve-sim must be
// streaming a device, and we need a udid to drive. Returns the resolved udid +
// serve-sim base url, or a ready-to-return error result. Keeps the readiness /
// resolution boilerplate out of each tool handler.
async function resolveControlTarget(
  toolName: string,
  udid: string | undefined,
): Promise<
  | { ok: true; udid: string; simUrl: string }
  | { ok: false; result: ReturnType<typeof toolErrorResult> }
> {
  const sim = getSimStatus();
  if (sim.phase !== 'ready') {
    const why = sim.phase === 'error' ? sim.message : sim.phase;
    return {
      ok: false,
      result: toolErrorResult(
        toolName,
        new Error(`simulator preview not ready (serve-sim: ${why})`),
      ),
    };
  }
  if (udid !== undefined && !isSafeUdid(udid)) {
    return {
      ok: false,
      result: toolErrorResult(
        toolName,
        new Error(`udid is not a valid simulator identifier: ${udid.slice(0, 64)}`),
      ),
    };
  }
  const resolved = await resolveActiveUdid(udid);
  if (!resolved) {
    return {
      ok: false,
      result: toolErrorResult(
        toolName,
        new Error('no booted iOS simulator to drive'),
      ),
    };
  }
  return { ok: true, udid: resolved, simUrl: sim.url };
}

// Map a serve-sim ControlResult to an MCP tool result: a failure becomes an
// error result carrying serve-sim's message; success returns `successText`.
function controlResultToTool(
  toolName: string,
  r: ControlResult,
  successText: string,
) {
  if (!r.ok) return toolErrorResult(toolName, new Error(r.message));
  return { content: [{ type: 'text' as const, text: successText }] };
}

function buildServer(): McpServer {
  const server = new McpServer(
    {
      name: 'tango-canvas',
      version: '0.1.0',
    },
    { instructions: TANGO_MCP_INSTRUCTIONS },
  );

  // UI mock tools — the design surface in the left pane. The terminal agent
  // writes a shadcn-based spec, the user drags/resizes/edits-text in the
  // browser, and the terminal agent reads the result back. The spec lives in
  // uiMockBridge's in-memory cache and syncs to the browser over /ws/ui-mock.
  // Element shape matches `UISpec` in src/lib/uiMockProtocol.ts.

  server.registerTool(
    'get_ui_mock',
    {
      title: 'Read the UI mock',
      description:
        "Returns the current UI mock spec — the user-tweakable shadcn/Tailwind design shown in the left pane. Each screen has a fixed-size `frame` (w×h px) and a flat list of `nodes` at absolute coordinates inside that frame. Call this BEFORE proposing changes — the user has likely dragged, resized, or edited text since you last set the mock, and those tweaks reflect their intent for the production UI. Pass `screenId` to read just one screen (much smaller — prefer it whenever the task concerns a single screen; unknown ids return an empty `screens` array). Empty `screens` array means nothing has been mocked yet.",
      inputSchema: {
        screenId: z.string().min(1).optional(),
      },
    },
    async ({ screenId }) => {
      const spec = getUIMock();
      const out: UISpec = screenId
        ? { ...spec, screens: spec.screens.filter((s) => s.id === screenId) }
        : spec;
      return {
        content: [{ type: 'text', text: JSON.stringify(out, null, 2) }],
      };
    },
  );

  server.registerTool(
    'get_ui_viewport',
    {
      title: 'Read the UI panel viewport size',
      description:
        "Returns the live pixel size of the largest frame that fits without scrolling in the user's design panel — already adjusted for the canvas's padding and per-screen title row. Call this BEFORE `set_ui_mock` / `add_ui_screen` when the user wants a mock that fills their current screen (the common case — anything other than an explicit mobile/tablet request). Use the returned `{w, h}` as the screen's frame size so the mock matches exactly what they see. Returns `{w: null, h: null}` if no measurement is available yet (no browser open this session, or right after a workspace switch before the new tab has measured) — fall back to 1280×800 in that case.",
    },
    async () => {
      const v = getUIViewport();
      return {
        content: [
          { type: 'text', text: JSON.stringify(v ?? { w: null, h: null }) },
        ],
      };
    },
  );

  server.registerTool(
    'set_ui_mock',
    {
      title: 'Replace the UI mock',
      description:
        "Replaces the entire UI mock spec — every screen, every node. Use for a fresh mock or a full redesign. Each screen needs a unique `id`, a `title`, a `frame` ({w,h} in pixels — default to the user's current panel size from `get_ui_viewport` so the mock fills their screen; use 360×720 for explicit mobile, 768×1024 for explicit tablet), and an array of `nodes`. Each node has a unique `id`, a `type` (one of: div, text, heading, Button, Input, Textarea, Badge, Separator, Image, Icon), absolute pixel coords (`x`,`y`,`width`,`height`) inside the frame, and optional `text` (label/placeholder), `className` (Tailwind for visuals using THEME tokens — `bg-card`, `text-muted-foreground`, etc.; layout-affecting classes are ignored, coords win), `style` (React inline-style object — use this for colors outside the app's theme palette like exact brand hex, gradients, and custom shadows; arbitrary-value Tailwind classes like `bg-[#hex]` do NOT work in `className` because the JIT only scans source files at build time, so off-theme color fidelity must come through `style`), and `props` (component-specific: Button/Badge `variant`, Input/Textarea `placeholder`, Image `src`, Icon `iconName` from lucide-react, heading `level` 1|2|3). Prefer `add_ui_screen` when extending an existing flow. Screens may carry an optional `sourceFile` (import provenance) — preserve it when echoing a spec back.",
      inputSchema: {
        spec: uiSpecSchema,
      },
    },
    async ({ spec }) => {
      try {
        setUIMockFromServer(spec as UISpec);
        const screenCount = spec.screens.length;
        const nodeCount = spec.screens.reduce(
          (sum, s) => sum + s.nodes.length,
          0,
        );
        return {
          content: [
            {
              type: 'text',
              text: `Replaced UI mock with ${screenCount} screen(s), ${nodeCount} node(s).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('set_ui_mock', err);
      }
    },
  );

  server.registerTool(
    'add_ui_screen',
    {
      title: 'Append a screen to the UI mock',
      description:
        "Appends one screen to the existing UI mock without disturbing other screens. Use this when iterating on a flow (auth → onboarding → dashboard) or adding a variant alongside existing work. The `screen` shape matches one element of `spec.screens` in `set_ui_mock`. Call `get_ui_mock` first if you need to align the new screen with existing frame sizes or naming conventions; for a brand-new flow, default the frame to the user's current panel size from `get_ui_viewport` (use 360×720 for explicit mobile, 768×1024 for explicit tablet). The screen id and every node id must be globally unique across the whole mock — this is enforced; the call errors listing every collision. Screens may carry an optional `sourceFile` (workspace-relative Swift file the screen was imported from) — set it only when the screen mirrors a real file, and preserve it when re-emitting an existing screen.",
      inputSchema: {
        screen: uiScreenSchema,
      },
    },
    async ({ screen }) => {
      try {
        appendUIScreenFromServer(screen as UIScreen);
        return {
          content: [
            {
              type: 'text',
              text: `Appended screen "${screen.title}" with ${screen.nodes.length} node(s).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('add_ui_screen', err);
      }
    },
  );

  server.registerTool(
    'clear_ui_mock',
    {
      title: 'Clear the UI mock',
      description:
        'Empties the UI mock — removes every screen and node. Reach for this when starting a fresh mock; otherwise prefer `set_ui_mock` (whole-spec replace) or `add_ui_screen` (extend) so user tweaks elsewhere are not silently dropped.',
    },
    async () => {
      clearUIMockFromServer();
      return { content: [{ type: 'text', text: 'UI mock cleared.' }] };
    },
  );

  // Node-level UI mock tools. These operate on the LIVE server cache (the
  // latest snapshot the browser pushed up), so they preserve the user's
  // drag/resize/text tweaks to every node except the one being changed —
  // unlike `set_ui_mock`, which replaces everything. Prefer these for
  // incremental edits. z-order = node array order: later = rendered on top.

  server.registerTool(
    'get_ui_layers',
    {
      title: 'Inspect the UI mock layer hierarchy',
      description:
        "Returns a compact, z-ordered outline of the UI mock — each screen and, within it, its nodes listed from back to front with a `z` index (array order; higher `z` = rendered on top), `id`, `type`, a truncated `text`, the bounding `rect`, and (when grouped) a `group` tag; the screen carries its `groups` registry (`{id, name}`). This is the cheap way to see the layer structure and grab real node/group ids before calling `update_ui_node`, `remove_ui_node`, `reorder_ui_node`, or the group tools (use `get_ui_mock` instead when you need the full styling/props of every node). Pass `screenId` to scope to one screen; omit it for all screens. An unknown `screenId` returns an empty `screens` array.",
      inputSchema: {
        screenId: z.string().optional(),
      },
    },
    async ({ screenId }) => {
      const layers = describeLayers(getUIMock(), screenId);
      return {
        content: [{ type: 'text', text: JSON.stringify(layers, null, 2) }],
      };
    },
  );

  server.registerTool(
    'add_ui_nodes',
    {
      title: 'Add nodes to a UI mock screen',
      description:
        "Appends one or more nodes to an existing screen (identified by `screenId`) WITHOUT touching the rest of the mock — operates on the live spec, so the user's drag/resize/text tweaks to other nodes survive. Prefer this over `set_ui_mock` whenever you're adding to an existing screen. New nodes land on TOP of the z-order (end of the screen's node list). Each node has a unique `id` (must not collide with any existing node), a `type` (div, text, heading, Button, Input, Textarea, Badge, Separator, Image, Icon), absolute pixel coords (`x`,`y`,`width`,`height`) inside the frame, and optional `text` / `className` (theme-token Tailwind for visuals; layout classes are ignored) / `style` (React inline-style for off-theme colors) / `props` (Button/Badge `variant`, Input/Textarea `placeholder`, Image `src`, Icon `iconName`, heading `level`). Call `get_ui_layers` or `get_ui_mock` first if you need the screen id or want to avoid overlapping existing nodes.",
      inputSchema: {
        screenId: z.string().min(1),
        nodes: z.array(uiNodeSchema).min(1),
      },
    },
    async ({ screenId, nodes }) => {
      try {
        addUINodesFromServer(screenId, nodes as UINode[]);
        const screen = getUIMock().screens.find((s) => s.id === screenId);
        return {
          content: [
            {
              type: 'text',
              text: `Added ${nodes.length} node(s) to screen "${screenId}" (now ${screen?.nodes.length ?? '?'} node(s)).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('add_ui_nodes', err);
      }
    },
  );

  server.registerTool(
    'update_ui_node',
    {
      title: 'Update a single UI mock node',
      description:
        "Shallow-merges a `patch` into one node, found by `nodeId` across all screens — operates on the live spec, so every other node's tweaks survive. Use this for targeted edits (move/resize a node, change its `text`, swap a Button `variant`, restyle via `className`/`style`) instead of replacing the whole spec with `set_ui_mock`. The patch may set any node field EXCEPT `id` (immutable): `type`, `x`, `y`, `width`, `height`, `text`, `className`, `style`, `props`. Omitted fields are left unchanged. Errors if the node id doesn't exist — call `get_ui_layers` first if unsure.",
      inputSchema: {
        nodeId: z.string().min(1),
        patch: uiNodePatchSchema,
      },
    },
    async ({ nodeId, patch }) => {
      try {
        updateUINodeFromServer(nodeId, patch);
        return {
          content: [
            { type: 'text', text: `Updated node "${nodeId}".` },
          ],
        };
      } catch (err) {
        return toolErrorResult('update_ui_node', err);
      }
    },
  );

  server.registerTool(
    'update_ui_nodes',
    {
      title: 'Update many UI mock nodes in one call',
      description:
        "Bulk version of `update_ui_node`: applies many small patches in ONE call — the cheap delta path for restyles, rearranges, and divergence after `duplicate_ui_screen` (emit only the fields that change, never regenerate whole nodes or screens). Each entry shallow-merges `patch` into the node found by `nodeId`; the same patch rules as `update_ui_node` apply (`id` immutable, omitted fields unchanged). All-or-nothing: unknown ids fail the whole call, listing every one. Patches to the same node merge in order.",
      inputSchema: {
        patches: z
          .array(
            z.object({
              nodeId: z.string().min(1),
              patch: uiNodePatchSchema,
            }),
          )
          .min(1),
      },
    },
    async ({ patches }) => {
      try {
        updateUINodesFromServer(patches);
        return {
          content: [
            {
              type: 'text',
              text: `Updated ${patches.length} node patch(es).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('update_ui_nodes', err);
      }
    },
  );

  server.registerTool(
    'remove_ui_node',
    {
      title: 'Remove UI mock node(s)',
      description:
        "Deletes one or more nodes by id (across any screen) from the live spec, leaving everything else intact. Pass `nodeIds` as an array. All-or-nothing: if ANY id doesn't exist the call fails and nothing is removed, so a typo can't silently drop the wrong node — call `get_ui_layers` first to confirm ids. To remove a whole screen, use `remove_ui_screen`.",
      inputSchema: {
        nodeIds: z.array(z.string().min(1)).min(1),
      },
    },
    async ({ nodeIds }) => {
      try {
        removeUINodesFromServer(nodeIds);
        return {
          content: [
            {
              type: 'text',
              text: `Removed ${nodeIds.length} node(s).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('remove_ui_node', err);
      }
    },
  );

  server.registerTool(
    'duplicate_ui_screen',
    {
      title: 'Duplicate a screen in the UI mock',
      description:
        "Copies an existing screen to a new screen appended at the end — the FAST first step for variations and iterations: the copy appears on the user's canvas instantly, then you diverge it with a few `update_ui_nodes` patches instead of regenerating every node. Node ids are remapped automatically (`<sourceId>-` prefixes become `<newScreenId>-`, others get `<newScreenId>-` prepended) and `sourceFile` is not copied. `newScreenId` must be globally unique (convention: `<sourceId>-v1`, `-v2`, …); `newTitle` defaults to \"<source title> copy\". Errors list every id collision.",
      inputSchema: {
        screenId: z.string().min(1),
        newScreenId: z.string().min(1),
        newTitle: z.string().min(1).optional(),
      },
    },
    async ({ screenId, newScreenId, newTitle }) => {
      try {
        duplicateUIScreenFromServer(screenId, newScreenId, newTitle);
        return {
          content: [
            {
              type: 'text',
              text: `Duplicated screen "${screenId}" as "${newScreenId}". Diverge it with update_ui_nodes (node ids now carry the "${newScreenId}-" prefix).`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('duplicate_ui_screen', err);
      }
    },
  );

  server.registerTool(
    'update_ui_screen',
    {
      title: 'Update a screen’s title or frame',
      description:
        'Patches screen-level fields (`title`, `frame`) of one screen without touching its nodes or any other screen. The screen `id` is immutable (export filenames and the simulator preview are keyed on it). Errors if the screen id does not exist.',
      inputSchema: {
        screenId: z.string().min(1),
        title: z.string().min(1).optional(),
        frame: z
          .object({ w: z.number().positive(), h: z.number().positive() })
          .optional(),
      },
    },
    async ({ screenId, title, frame }) => {
      if (title === undefined && frame === undefined) {
        return toolErrorResult(
          'update_ui_screen',
          new Error('Provide at least one of `title` or `frame`.'),
        );
      }
      try {
        updateUIScreenFromServer(screenId, { title, frame });
        return {
          content: [
            { type: 'text', text: `Updated screen "${screenId}".` },
          ],
        };
      } catch (err) {
        return toolErrorResult('update_ui_screen', err);
      }
    },
  );

  server.registerTool(
    'remove_ui_screen',
    {
      title: 'Remove a screen from the UI mock',
      description:
        'Deletes one screen (and all its nodes) from the live spec, leaving every other screen untouched — the safe way to discard a rejected variation or clean up, instead of `set_ui_mock` (whole-spec replace, which risks clobbering concurrent user edits). Errors if the screen id does not exist — call `get_ui_layers` first to confirm ids.',
      inputSchema: {
        screenId: z.string().min(1),
      },
    },
    async ({ screenId }) => {
      try {
        removeUIScreenFromServer(screenId);
        return {
          content: [
            { type: 'text', text: `Removed screen "${screenId}".` },
          ],
        };
      } catch (err) {
        return toolErrorResult('remove_ui_screen', err);
      }
    },
  );

  server.registerTool(
    'reorder_ui_node',
    {
      title: 'Reorder a UI mock node in the z-stack',
      description:
        "Changes a node's z-order (stacking) within its own screen. `op` is one of: `front` (move to top of the stack), `back` (move to bottom), `forward` (move up one — render above the next sibling), `backward` (move down one). z-order is the node array order: a node later in the list paints over earlier ones, so 'front' = end of the list. A move at a boundary (already on top/bottom) is a harmless no-op. Use `get_ui_layers` to see current stacking and ids. Errors if the node id doesn't exist.",
      inputSchema: {
        nodeId: z.string().min(1),
        op: reorderOpEnum,
      },
    },
    async ({ nodeId, op }) => {
      try {
        reorderUINodeFromServer(nodeId, op);
        return {
          content: [
            { type: 'text', text: `Moved node "${nodeId}" ${op}.` },
          ],
        };
      } catch (err) {
        return toolErrorResult('reorder_ui_node', err);
      }
    },
  );

  server.registerTool(
    'group_ui_nodes',
    {
      title: 'Group UI mock nodes',
      description:
        "Creates an editor-level group from nodes on ONE screen: members get a `group` tag, the screen's `groups` registry gains `{id, name}`, and members are made z-contiguous (the block lands where the topmost member sat). Groups are an organization/selection aid — the layers tree nests them and the canvas selects them as one; they never change rendering or export. Nodes already in another group are stolen (emptied groups are pruned). Omit `id`/`name` to auto-assign (`group-N` / `Group N`). Errors: unknown screen, nodes not on that screen, explicit id already taken.",
      inputSchema: {
        screenId: z.string().min(1),
        nodeIds: z.array(z.string().min(1)).min(1),
        id: z.string().min(1).optional(),
        name: z.string().min(1).optional(),
      },
    },
    async ({ screenId, nodeIds, id, name }) => {
      try {
        groupUINodesFromServer(screenId, nodeIds, { id, name });
        return {
          content: [
            {
              type: 'text',
              text: `Grouped ${nodeIds.length} node(s) on "${screenId}".`,
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('group_ui_nodes', err);
      }
    },
  );

  server.registerTool(
    'ungroup_ui_nodes',
    {
      title: 'Ungroup UI mock nodes',
      description:
        'Dissolves one group: members lose their `group` tag (keeping their exact z positions), the registry entry is removed. Errors if no screen has the group id — `get_ui_layers` shows current groups.',
      inputSchema: {
        groupId: z.string().min(1),
      },
    },
    async ({ groupId }) => {
      try {
        ungroupUINodesFromServer(groupId);
        return {
          content: [{ type: 'text', text: `Ungrouped "${groupId}".` }],
        };
      } catch (err) {
        return toolErrorResult('ungroup_ui_nodes', err);
      }
    },
  );

  server.registerTool(
    'rename_ui_group',
    {
      title: 'Rename a UI mock group',
      description:
        'Renames an existing group (the label shown in the layers tree). Errors on an unknown group id or an empty name.',
      inputSchema: {
        groupId: z.string().min(1),
        name: z.string().min(1),
      },
    },
    async ({ groupId, name }) => {
      try {
        renameUIGroupFromServer(groupId, name);
        return {
          content: [
            { type: 'text', text: `Renamed group "${groupId}" to "${name}".` },
          ],
        };
      } catch (err) {
        return toolErrorResult('rename_ui_group', err);
      }
    },
  );

  // iOS build / install / launch tools. Available regardless of whether the
  // workspace contains an Xcode project — `ios_status` returns `project.kind:
  // 'none'` if not, and the skill (`tango-ios-sim`) tells the terminal agent to
  // bail out gracefully in that case.

  server.registerTool(
    'ios_status',
    {
      title: 'Detected Xcode project + booted simulators',
      description:
        "Read-only summary of the iOS dev environment for the current workspace. Returns the detected Xcode project (`kind: 'none' | 'detected' | 'ambiguous' | 'error'`), the booted simulators (`xcrun simctl list devices booted`), and the active device UDID — preferring the simulator that `serve-sim` is currently iframing in tango's right sidebar so your build targets the device the user is actually watching. Call this once at the START of a session to confirm the project is detected and a simulator is booted, OR whenever device/scheme intent changes (user says \"switch to iPad\", \"use the prod scheme\"). Don't pre-call before every `ios_build_run` — that tool already re-resolves the active device internally, and the `simctl list` shell-out is wasted latency on every rebuild.",
    },
    async () => {
      try {
        const project = getIosProject();
        const bootedDevices = await listBootedDevices();
        const sim = getSimStatus();
        let activeDeviceUdid: string | null = null;
        if (sim.phase === 'ready') {
          activeDeviceUdid = await readActiveDeviceFromServeSim(sim.url);
        }
        if (!activeDeviceUdid && bootedDevices.length > 0) {
          activeDeviceUdid = bootedDevices[0].udid;
        }
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(
                { project, bootedDevices, activeDeviceUdid },
                null,
                2,
              ),
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('ios_status', err);
      }
    },
  );

  server.registerTool(
    'ios_build_run',
    {
      title: 'Build the Xcode project, install on the simulator, launch',
      description:
        "Atomic `xcodebuild → simctl install → simctl terminate → simctl launch` against the booted iOS simulator. Headline tool of the `tango-ios-sim` skill — call after every batch of Swift edits the user accepts so the simulator (which they're watching iframed in the right sidebar) reflects the change. The build is incremental, so the second+ rebuild is fast (~5–15s on M-series). All inputs are optional and default to the values from `ios_status`: `scheme` (from the detected project), `udid` (from serve-sim's active device, or the first booted simulator), `configuration` ('Debug'), `bringForeground` (true — terminate-then-launch so the running app refreshes). On failure, returns `{ok:false, stage, message, errors}` where `errors` is the deduplicated `xcodebuild` `error:` lines (capped at 20) — surface those to the user, don't dump the full log.",
      inputSchema: {
        scheme: z.string().optional(),
        udid: z.string().optional(),
        configuration: z.enum(['Debug', 'Release']).optional(),
        bringForeground: z.boolean().optional(),
      },
    },
    async ({ scheme, udid, configuration, bringForeground }) => {
      try {
        const workspace = getWorkspaceOrNull();
        if (!workspace) {
          return toolErrorResult(
            'ios_build_run',
            new Error('no workspace selected'),
          );
        }
        // Shared resolution with Export & Run (iosExport.ts) — handles the
        // none/error/ambiguous cases and the duplicate-scheme trap (two
        // projects sharing a scheme name would otherwise silently build the
        // wrong codebase).
        const projectResult = resolveBuildProject(scheme);
        if (!projectResult.ok) {
          return iosBuildErrorResult('detect', projectResult.message);
        }
        const project = projectResult.project;

        // Resolve the device (explicit udid → serve-sim's active device →
        // first booted). See `resolveActiveUdid` in iosBuild.ts.
        const resolvedUdid = await resolveActiveUdid(udid);
        if (!resolvedUdid) {
          return iosBuildErrorResult(
            'detect',
            'no booted iOS simulator (boot one from Xcode → Open Developer Tool → Simulator)',
          );
        }

        const result = await iosBuildRun(workspace, project, {
          scheme,
          udid: resolvedUdid,
          configuration,
          bringForeground,
        });
        return {
          content: [
            { type: 'text', text: JSON.stringify(result, null, 2) },
          ],
        };
      } catch (err) {
        return toolErrorResult('ios_build_run', err);
      }
    },
  );

  server.registerTool(
    'preview_start',
    {
      title: 'Launch the live design preview on the simulator',
      description:
        "Builds (first run only, ~30–60s; warm runs ~2–4s), installs, and launches tango's preview-host app on the booted iOS simulator. Once running it renders the design spec live: every canvas edit — the user's drags, your set_ui_mock / update_ui_node calls — appears on the simulator in under a second with NO rebuild. xcodebuild is only needed again for `export_run` (real code). Idempotent: if the app is already running and connected this just brings it to the foreground (use it to get back to the preview after `export_run` launches the exported app over it). The result's `connected` tells you whether the app's WebSocket is attached; `running` + `connected: false` usually means the user closed the app — calling this again relaunches it. Pass `udid` only to target a specific simulator.",
      inputSchema: {
        udid: z.string().optional(),
      },
    },
    async ({ udid }) => {
      try {
        await startPreviewHost({ udid });
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(getPreviewHostStatus(), null, 2),
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('preview_start', err);
      }
    },
  );

  server.registerTool(
    'export_run',
    {
      title: 'Export the design to SwiftUI and run it on the simulator',
      description:
        "Deterministically generates SwiftUI from the current design spec into `TangoGenerated/` inside the detected Xcode project, then builds, installs, and launches on the booted simulator — the no-LLM fast path from canvas to running app. One file per screen (`Tango<Name>Screen`), plus `TangoGeneratedRootView` (a TabView over all screens) to embed wherever the design should appear. Files under `TangoGenerated/` are tango-owned: regenerated on every export, never hand-edit them — to change those screens, change the design and re-export. Inputs are all optional and mirror `ios_build_run` (`scheme`, `udid`, `configuration`). The result includes `inclusion`: `'fs-synced'` means the project picks the folder up automatically (Xcode 16 filesystem-synchronized groups); `'manual-add-required'` means the user must drag `TangoGenerated/` into their target in Xcode once — tell them so. The result also includes `embedded`: `false` means no user Swift file references the generated views, so the launched app looks unchanged — offer to embed `TangoGeneratedRootView()` for the user (e.g. in place of the template `ContentView()` in their `App`'s `WindowGroup`); that's a normal user-code edit you may make. Fails fast when the design is empty or no simulator is booted.",
      inputSchema: {
        scheme: z.string().optional(),
        udid: z.string().optional(),
        configuration: z.enum(['Debug', 'Release']).optional(),
      },
    },
    async ({ scheme, udid, configuration }) => {
      try {
        const state = await runExportAndRun({ scheme, udid, configuration });
        return {
          content: [{ type: 'text', text: JSON.stringify(state, null, 2) }],
        };
      } catch (err) {
        return toolErrorResult('export_run', err);
      }
    },
  );

  server.registerTool(
    'ios_logs_recent',
    {
      title: 'Recent unified-log entries from the running app',
      description:
        "Reads recent log entries from the booted simulator scoped to the running app's bundle id (`subsystem == \"<bundleId>\"`) and process name (`processImagePath CONTAINS \"<targetName>\"`). Use after `ios_build_run` to investigate runtime issues the user reports. `sinceSeconds` defaults to 30; raise if the issue happened earlier. Pass `bundleId` explicitly when the workspace's detection is `ambiguous` (so there's no auto-resolved bundle id) or when targeting a different installed app. Returns at most 500 entries; `truncated: true` means there were more.",
      inputSchema: {
        udid: z.string().optional(),
        bundleId: z.string().optional(),
        sinceSeconds: z.number().int().positive().max(3600).optional(),
      },
    },
    async ({ udid, bundleId, sinceSeconds }) => {
      try {
        const detectedBundleId =
          (() => {
            const p = getIosProject();
            return p.kind === 'detected' ? p.project.bundleId : null;
          })();
        const resolvedBundleId = bundleId ?? detectedBundleId;
        if (!resolvedBundleId) {
          return toolErrorResult(
            'ios_logs_recent',
            new Error(
              'no bundle id available — run `ios_build_run` first, call `ios_status` to confirm detection, or pass `bundleId` explicitly',
            ),
          );
        }
        const resolvedUdid = await resolveActiveUdid(udid);
        if (!resolvedUdid) {
          return toolErrorResult(
            'ios_logs_recent',
            new Error('no booted iOS simulator'),
          );
        }
        const result = await iosLogsRecent({
          udid: resolvedUdid,
          bundleId: resolvedBundleId,
          sinceSeconds,
        });
        // Surface validator rejections structurally so the terminal agent
        // doesn't mistake them for "no entries in the window."
        if (result.rejected) {
          return toolErrorResult(
            'ios_logs_recent',
            new Error(`request rejected: ${result.rejected}`),
          );
        }
        return {
          content: [
            { type: 'text', text: JSON.stringify(result, null, 2) },
          ],
        };
      } catch (err) {
        return toolErrorResult('ios_logs_recent', err);
      }
    },
  );

  // iOS simulator *control* tools — drive the running app the user is watching
  // in the iframe (serve-sim CLI under the hood). Aim with `ios_inspect` first;
  // coordinates everywhere are normalized 0..1. Terminal-agent only; not in
  // the controller agent's ALLOWED_TOOLS (it can't see the simulator).

  server.registerTool(
    'ios_inspect',
    {
      title: 'Inspect the simulator screen (accessibility tree)',
      description:
        "Returns serve-sim's accessibility snapshot of whatever the booted simulator is currently showing: `screen` ({width, height} in device points) and `elements` — each with `label`, `value`, `role`, `type`, `enabled`, a pixel `frame`, and a `centerNorm` {x, y} in normalized 0..1 coords ready to hand straight to `ios_tap`. This is how you AIM: you can't see the simulator's pixels, so call `ios_inspect` to find a control by its label/role, then tap its `centerNorm` — don't guess coordinates. If accessibility is momentarily unavailable the result carries an `errors` array; retry shortly. Pass `udid` only to target a specific simulator (defaults to the one serve-sim is streaming).",
      inputSchema: {
        udid: z.string().optional(),
      },
    },
    async ({ udid }) => {
      try {
        const target = await resolveControlTarget('ios_inspect', udid);
        if (!target.ok) return target.result;
        const snapshot = await fetchAxSnapshot(target.simUrl, target.udid);
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(toInspectResult(snapshot), null, 2),
            },
          ],
        };
      } catch (err) {
        return toolErrorResult('ios_inspect', err);
      }
    },
  );

  server.registerTool(
    'ios_tap',
    {
      title: 'Tap the simulator screen',
      description:
        "Tap the booted iOS simulator once at normalized coordinates `x`, `y` (0..1; 0,0 = top-left, 1,1 = bottom-right). Find the target first with `ios_inspect` and pass the element's `centerNorm`. Pass `udid` only to override the simulator serve-sim is streaming.",
      inputSchema: {
        x: z.number(),
        y: z.number(),
        udid: z.string().optional(),
      },
    },
    async ({ x, y, udid }) => {
      try {
        const v = validateNormalized(x, y);
        if (!v.ok) return toolErrorResult('ios_tap', new Error(v.reason));
        const target = await resolveControlTarget('ios_tap', udid);
        if (!target.ok) return target.result;
        const r = await iosTap(target.udid, x, y);
        return controlResultToTool('ios_tap', r, `Tapped (${x}, ${y}).`);
      } catch (err) {
        return toolErrorResult('ios_tap', err);
      }
    },
  );

  server.registerTool(
    'ios_gesture',
    {
      title: 'Swipe / drag on the simulator',
      description:
        "Drag on the booted simulator from (`fromX`, `fromY`) to (`toX`, `toY`), all normalized 0..1 (0,0 = top-left, 1,1 = bottom-right). Use for swipes (scroll a list, swipe between pages, pull to refresh) and drags. The touch travels from → to: to swipe up, start at a larger y and end at a smaller y (e.g. from {0.5, 0.8} to {0.5, 0.2}). Aim endpoints with `ios_inspect` `centerNorm` values where possible. Note: each touch frame is a separate serve-sim call, so very fast continuous drags may register imperfectly. Pass `udid` only to override the active simulator.",
      inputSchema: {
        fromX: z.number(),
        fromY: z.number(),
        toX: z.number(),
        toY: z.number(),
        udid: z.string().optional(),
      },
    },
    async ({ fromX, fromY, toX, toY, udid }) => {
      try {
        const a = validateNormalized(fromX, fromY);
        if (!a.ok) return toolErrorResult('ios_gesture', new Error(`from: ${a.reason}`));
        const b = validateNormalized(toX, toY);
        if (!b.ok) return toolErrorResult('ios_gesture', new Error(`to: ${b.reason}`));
        const target = await resolveControlTarget('ios_gesture', udid);
        if (!target.ok) return target.result;
        const r = await iosGesture(target.udid, fromX, fromY, toX, toY);
        return controlResultToTool(
          'ios_gesture',
          r,
          `Swiped (${fromX}, ${fromY}) → (${toX}, ${toY}).`,
        );
      } catch (err) {
        return toolErrorResult('ios_gesture', err);
      }
    },
  );

  server.registerTool(
    'ios_button',
    {
      title: 'Press a simulator hardware button',
      description:
        "Press a hardware button on the booted simulator. `name` defaults to `home`; other names depend on the simulator (commonly `lock`, `siri`, `side`) and serve-sim validates them — an unsupported name comes back as an error. Use `home` to go to the home screen, `lock` to lock/wake. Pass `udid` only to override the active simulator.",
      inputSchema: {
        name: z.string().optional(),
        udid: z.string().optional(),
      },
    },
    async ({ name, udid }) => {
      try {
        const button = name ?? 'home';
        if (!isValidButtonName(button)) {
          return toolErrorResult(
            'ios_button',
            new Error(
              `invalid button name "${button.slice(0, 32)}" — expected a lowercase token like "home", "lock", "siri", "side"`,
            ),
          );
        }
        const target = await resolveControlTarget('ios_button', udid);
        if (!target.ok) return target.result;
        const r = await iosButton(target.udid, button);
        return controlResultToTool('ios_button', r, `Pressed "${button}".`);
      } catch (err) {
        return toolErrorResult('ios_button', err);
      }
    },
  );

  server.registerTool(
    'ios_type',
    {
      title: 'Type text into the simulator',
      description:
        "Type `text` into the booted simulator's currently focused field (US keyboard only). Tap the field first with `ios_tap` so it has focus. Sends the literal characters; it does not press Return — submit by tapping the submit control or pressing a button. Pass `udid` only to override the active simulator.",
      inputSchema: {
        text: z.string().min(1).max(2000),
        udid: z.string().optional(),
      },
    },
    async ({ text, udid }) => {
      try {
        const target = await resolveControlTarget('ios_type', udid);
        if (!target.ok) return target.result;
        const r = await iosType(target.udid, text);
        return controlResultToTool(
          'ios_type',
          r,
          `Typed ${text.length} character(s).`,
        );
      } catch (err) {
        return toolErrorResult('ios_type', err);
      }
    },
  );

  server.registerTool(
    'ios_rotate',
    {
      title: 'Rotate the simulator',
      description: `Set the booted simulator's orientation. \`orientation\` is one of: ${ROTATE_ORIENTATIONS.join(', ')}. Pass \`udid\` only to override the active simulator.`,
      inputSchema: {
        orientation: z.string(),
        udid: z.string().optional(),
      },
    },
    async ({ orientation, udid }) => {
      try {
        if (!isValidOrientation(orientation)) {
          return toolErrorResult(
            'ios_rotate',
            new Error(
              `invalid orientation "${orientation.slice(0, 32)}" — expected one of: ${ROTATE_ORIENTATIONS.join(', ')}`,
            ),
          );
        }
        const target = await resolveControlTarget('ios_rotate', udid);
        if (!target.ok) return target.result;
        const r = await iosRotate(target.udid, orientation);
        return controlResultToTool('ios_rotate', r, `Rotated to ${orientation}.`);
      } catch (err) {
        return toolErrorResult('ios_rotate', err);
      }
    },
  );

  server.registerTool(
    'remember_note',
    {
      title: 'Record a workspace memory note',
      description:
        'Append a one-line note to ./tango-memory.md so future sessions in this workspace pick it up. Use this when the user states a design decision, constraint, or piece of context worth remembering — e.g. "auth uses magic links, no passwords", "primary brand color is #4F46E5", "TODO: revisit empty-state copy after launch". `category` is one of: `decision` (a settled choice that should not be re-litigated), `context` (background fact about the project), `todo` (something to come back to). Keep `text` short and self-contained — the user will read these as bullet points later.',
      inputSchema: {
        category: z.enum(['decision', 'context', 'todo']),
        text: z.string().min(1).max(500),
      },
    },
    async ({ category, text }) => {
      recordNote(category, text);
      return {
        content: [
          {
            type: 'text',
            text: `Recorded ${category} note in tango-memory.md.`,
          },
        ],
      };
    },
  );

  return server;
}

// Read the entire request body (POST /mcp arrives as JSON).
async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as ArrayBuffer));
  }
  if (chunks.length === 0) return undefined;
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return undefined;
  return JSON.parse(raw);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(body));
}

export function mountMcp(server: http.Server, mcpPath = '/mcp'): void {
  // session-id → (transport, mcpServer) so multiple clients can talk
  // simultaneously without sharing protocol state.
  const transports: Record<
    string,
    { transport: StreamableHTTPServerTransport; mcpServer: McpServer }
  > = {};

  const handleMcp = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const sessionId = req.headers['mcp-session-id'];
    const sid = Array.isArray(sessionId) ? sessionId[0] : sessionId;

    try {
      if (req.method === 'POST') {
        const body = await readJsonBody(req);

        if (sid && transports[sid]) {
          await transports[sid].transport.handleRequest(req, res, body);
          return;
        }

        if (!sid && isInitializeRequest(body)) {
          const mcpServer = buildServer();
          const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: () => randomUUID(),
            // DNS rebinding protection — we're localhost-only.
            enableDnsRebindingProtection: true,
            allowedHosts: ['localhost', '127.0.0.1', `localhost:${tangoPort()}`, `127.0.0.1:${tangoPort()}`],
            onsessioninitialized: (newSid) => {
              transports[newSid] = { transport, mcpServer };
            },
          });
          // Do NOT call mcpServer.close() here. The server's close() calls
          // transport.close(), which fires this onclose again — infinite
          // recursion. Dropping the session entry is enough; the McpServer
          // will be GC'd once nothing else references it.
          transport.onclose = () => {
            const closedSid = transport.sessionId;
            if (closedSid && transports[closedSid]) {
              delete transports[closedSid];
            }
          };
          await mcpServer.connect(transport);
          await transport.handleRequest(req, res, body);
          return;
        }

        sendJson(res, 400, {
          jsonrpc: '2.0',
          error: { code: -32000, message: 'Bad Request: invalid or missing session ID' },
          id: null,
        });
        return;
      }

      if (req.method === 'GET' || req.method === 'DELETE') {
        if (!sid || !transports[sid]) {
          res.statusCode = 400;
          res.end('Invalid or missing session ID');
          return;
        }
        await transports[sid].transport.handleRequest(req, res);
        return;
      }

      res.statusCode = 405;
      res.setHeader('Allow', 'POST, GET, DELETE');
      res.end('Method Not Allowed');
    } catch (err) {
      console.error('[mcp] request error', err);
      if (!res.headersSent) {
        sendJson(res, 500, {
          jsonrpc: '2.0',
          error: { code: -32603, message: 'Internal server error' },
          id: null,
        });
      }
    }
  };

  // Hook the existing 'request' listener: route /mcp prefix to MCP, fall
  // through to whatever Next handler the host registered for everything else.
  // We capture the existing listeners, remove them, install our shim, and
  // re-fire them for non-/mcp requests.
  const existingListeners = server.listeners('request') as Array<
    (req: IncomingMessage, res: ServerResponse) => void
  >;
  server.removeAllListeners('request');
  server.on('request', (req, res) => {
    if (req.url && (req.url === mcpPath || req.url.startsWith(`${mcpPath}?`) || req.url.startsWith(`${mcpPath}/`))) {
      void handleMcp(req, res);
      return;
    }
    for (const listener of existingListeners) listener(req, res);
  });
}
