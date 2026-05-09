// In-process MCP server. Mounted on the bare http.createServer in server.ts —
// NOT under app/api/.../route.ts, because the Streamable HTTP transport wants
// Node IncomingMessage/ServerResponse, not Web Fetch Request/Response.
//
// Tools live alongside canvasBridge in the same Node process so they can read
// and write the scene cache without IPC. The browser is told about scene
// changes via the /ws/canvas bridge.

import { randomUUID } from 'node:crypto';
import type http from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import * as z from 'zod/v4';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import {
  appendElementsFromServer,
  clearCanvasFromServer,
  getCanvasState,
  requestScreenshot,
  setCanvasFromServer,
} from './canvasBridge';
import {
  appendUIScreenFromServer,
  clearUIMockFromServer,
  getUIMock,
  getUIViewport,
  setUIMockFromServer,
} from './uiMockBridge';
import type { CanvasElement } from '@/lib/canvasProtocol';
import type { UIScreen, UISpec } from '@/lib/uiMockProtocol';
import {
  type Edge as FlowEdge,
  type Screen as FlowScreen,
  layoutScreenFlow,
  screenFlowElements,
  validateScreenFlowInput,
} from './screenFlow';
import { recordNote } from './memory';
import { getIosProject, getWorkspaceOrNull } from './workspace';
import {
  iosBuildRun,
  iosLogsRecent,
  listBootedDevices,
  readActiveDeviceFromServeSim,
} from './iosBuild';
import { getSimStatus } from './sim';

const elementSchema = z.array(z.record(z.string(), z.unknown()));
// Permissive Zod shape — we don't reproduce Excalidraw's element schema here.
// Excalidraw will reject malformed elements at updateScene() time on the
// client; we surface that as the tool result.

// UI mock spec — keep this aligned with src/lib/uiMockProtocol.ts. Strict
// enum on `type` and required positioning so Claude gets a useful validation
// error instead of nodes silently rendering as `null`.
const uiNodeTypeEnum = z.enum([
  'div',
  'text',
  'heading',
  'Button',
  'Input',
  'Textarea',
  'Badge',
  'Separator',
  'Image',
  'Icon',
]);

const uiNodeSchema = z.object({
  id: z.string().min(1),
  type: uiNodeTypeEnum,
  x: z.number(),
  y: z.number(),
  width: z.number().positive(),
  height: z.number().positive(),
  text: z.string().optional(),
  className: z.string().optional(),
  style: z.record(z.string(), z.union([z.string(), z.number()])).optional(),
  props: z.record(z.string(), z.unknown()).optional(),
});

const uiScreenSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  frame: z.object({
    w: z.number().int().positive(),
    h: z.number().int().positive(),
  }),
  nodes: z.array(uiNodeSchema),
});

const uiSpecSchema = z.object({
  screens: z.array(uiScreenSchema),
});

// Screen-flow spec — the input shape for `set_screen_flow`. Aligned with
// `Screen` / `Edge` in src/server/screenFlow.ts. Strict enums on `kind` so
// the model gets a useful validation error for typos. Bounded fields
// keep the rendered card readable; `name.max(120)` accommodates real UIKit
// `ViewController` names that routinely exceed 60 chars.
const flowScreenSchema = z.object({
  id: z.string().min(1).max(120),
  name: z.string().min(1).max(120),
  kind: z.enum(['swiftui', 'uikit', 'storyboard']),
  filePath: z.string().max(240).optional(),
  summary: z.string().max(120).optional(),
  isEntry: z.boolean().optional(),
});

const flowEdgeSchema = z.object({
  from: z.string().min(1).max(120),
  to: z.string().min(1).max(120),
  kind: z.enum(['push', 'sheet', 'cover', 'present', 'segue', 'tab']),
  // Cap matches the in-card truncation budget — kept in sync so Claude
  // can't silently lose chars to a render-time `slice` that the schema
  // didn't warn about.
  label: z.string().max(24).optional(),
});

const flowOptionsSchema = z
  .object({
    append: z.boolean().optional(),
    cardWidth: z.number().int().min(120).max(800).optional(),
    cardHeight: z.number().int().min(80).max(600).optional(),
    origin: z
      .object({
        x: z.number().min(-10000).max(10000),
        y: z.number().min(-10000).max(10000),
      })
      .optional(),
  })
  .optional();

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
// errors}` returns so the model doesn't have to parse two formats.
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

function buildServer(): McpServer {
  const server = new McpServer({
    name: 'tango-canvas',
    version: '0.1.0',
  });

  server.registerTool(
    'get_canvas_state',
    {
      title: 'Read the canvas',
      description:
        'Returns the current Excalidraw scene. `elements` is the array shape produced by the `elements` field of `serializeAsJSON`. `fileKeys` lists the IDs of any embedded image files in the scene; the binary file bytes themselves are not inlined to keep the response small.',
    },
    async () => {
      const { elements, appState, files } = getCanvasState();
      const payload = {
        elements,
        appState,
        fileKeys: Object.keys(files),
      };
      return {
        content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
      };
    },
  );

  server.registerTool(
    'set_canvas_state',
    {
      title: 'Replace the canvas',
      description:
        'Replaces the entire canvas with the provided elements. `elements` must match the shape of the `elements` field returned by `get_canvas_state`. Call `get_canvas_state` first if you need to see the current scene shape. Useful for proposing wireframes or full-screen redesigns.',
      inputSchema: {
        elements: elementSchema,
        appState: z.record(z.string(), z.unknown()).optional(),
      },
    },
    async ({ elements, appState }) => {
      setCanvasFromServer(elements as CanvasElement[], appState);
      return {
        content: [
          {
            type: 'text',
            text: `Replaced canvas with ${elements.length} element(s).`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'add_elements',
    {
      title: 'Append to the canvas',
      description:
        'Appends new elements to the existing canvas without disturbing what is already there. `elements` must match the shape of the `elements` field returned by `get_canvas_state`. Useful for adding annotations, callouts, or new shapes alongside existing work.',
      inputSchema: {
        elements: elementSchema,
      },
    },
    async ({ elements }) => {
      appendElementsFromServer(elements as CanvasElement[]);
      return {
        content: [
          {
            type: 'text',
            text: `Appended ${elements.length} element(s) to the canvas.`,
          },
        ],
      };
    },
  );

  server.registerTool(
    'clear_canvas',
    {
      title: 'Clear the canvas',
      description: 'Empties the canvas. Existing app state and embedded files are preserved.',
    },
    async () => {
      clearCanvasFromServer();
      return { content: [{ type: 'text', text: 'Canvas cleared.' }] };
    },
  );

  server.registerTool(
    'screenshot_canvas',
    {
      title: 'See the canvas',
      description:
        "Returns the current Excalidraw canvas as a rendered image (vs. `get_canvas_state`'s scene JSON), so you can actually see what the user has drawn — including embedded screenshots whose bytes `get_canvas_state` strips. Reflects the live browser canvas at call time, with no debounce window. Safe to call in a loop. Defaults to a JPEG ~1024px on the longest side, which is plenty for vision and keeps round-trips fast; pass `maxDim` (up to 4096) for more detail or a smaller value for faster polling, and `quality` (0.1–1) to tune JPEG compression.",
      inputSchema: {
        maxDim: z.number().int().positive().max(4096).optional(),
        quality: z.number().min(0.1).max(1).optional(),
      },
    },
    async ({ maxDim, quality }) => {
      try {
        const { mime, data } = await requestScreenshot({ maxDim, quality });
        return {
          content: [{ type: 'image', data, mimeType: mime }],
        };
      } catch (err) {
        return toolErrorResult('screenshot_canvas', err);
      }
    },
  );

  server.registerTool(
    'set_screen_flow',
    {
      title: 'Render an app screen-flow diagram',
      description:
        "Render an app's screens + navigation as a Figma-style flow diagram on the Excalidraw canvas. Hand it a parsed graph: `screens` (each with stable `id`, `name` ≤120 chars, `kind`: 'swiftui' | 'uikit' | 'storyboard', optional `filePath`, `summary` ≤120 chars, and `isEntry` for the launch screen) plus `edges` connecting screen ids by navigation `kind` ('push' | 'sheet' | 'cover' | 'present' | 'segue' | 'tab', with optional `label` ≤24 chars). The tool runs a layered BFS layout (entries on top, children below), draws each screen as a rounded card with title + meta + summary, and connects them with kind-colored arrows. Defaults to replacing the canvas; pass `options.append: true` to add alongside existing content — when appending, also pass `options.origin: {x, y}` pointing at empty space (call `get_canvas_state` first to find a free area), or the new diagram lands on top of the existing one at the default `(200, 200)`. Use this once with the full graph rather than dribbling elements in via `add_elements`. Designed for the `tango-ios-map` skill.",
      inputSchema: {
        screens: z.array(flowScreenSchema).min(1).max(300),
        edges: z.array(flowEdgeSchema).max(3000),
        options: flowOptionsSchema,
      },
    },
    async ({ screens, edges, options }) => {
      const screenList = screens as FlowScreen[];
      const edgeList = edges as FlowEdge[];
      const validation = validateScreenFlowInput(screenList, edgeList);
      if (validation) {
        return toolErrorResult('set_screen_flow', new Error(validation));
      }
      const layout = layoutScreenFlow(screenList, edgeList, {
        cardWidth: options?.cardWidth,
        cardHeight: options?.cardHeight,
        originX: options?.origin?.x,
        originY: options?.origin?.y,
      });
      const elements = screenFlowElements(screenList, edgeList, layout);
      if (options?.append) {
        appendElementsFromServer(elements);
      } else {
        setCanvasFromServer(elements);
      }
      return {
        content: [
          {
            type: 'text',
            text: `Rendered ${screenList.length} screen(s), ${edgeList.length} edge(s) on the canvas.`,
          },
        ],
      };
    },
  );

  // UI mock tools. Sibling tool group to the canvas tools but for the "UI"
  // mode panel — Claude writes a shadcn-based mock spec, the user drags/
  // resizes/edits-text in the browser, and Claude reads the result back. The
  // spec lives in uiMockBridge's in-memory cache and syncs to the browser
  // over /ws/ui-mock. Element shape matches `UISpec` in
  // src/lib/uiMockProtocol.ts.

  server.registerTool(
    'get_ui_mock',
    {
      title: 'Read the UI mock',
      description:
        "Returns the current UI mock spec — the user-tweakable shadcn/Tailwind prototype shown in the left pane when the workspace is in 'UI' mode. Each screen has a fixed-size `frame` (w×h px) and a flat list of `nodes` at absolute coordinates inside that frame. Call this BEFORE proposing changes — the user has likely dragged, resized, or edited text since you last set the mock, and those tweaks reflect their intent for the production UI. Empty `screens` array means nothing has been mocked yet.",
    },
    async () => {
      const spec = getUIMock();
      return {
        content: [{ type: 'text', text: JSON.stringify(spec, null, 2) }],
      };
    },
  );

  server.registerTool(
    'get_ui_viewport',
    {
      title: 'Read the UI panel viewport size',
      description:
        "Returns the live pixel size of the largest frame that fits without scrolling in the user's UI mode panel — already adjusted for the canvas's padding and per-screen title row. Call this BEFORE `set_ui_mock` / `add_ui_screen` when the user wants a mock that fills their current screen (the common case — anything other than an explicit mobile/tablet request). Use the returned `{w, h}` as the screen's frame size so the mock matches exactly what they see. Returns `{w: null, h: null}` if no measurement is available yet (no browser open this session, or right after a workspace switch before the new tab has measured) — fall back to 1280×800 in that case.",
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
        "Replaces the entire UI mock spec — every screen, every node. Use for a fresh mock or a full redesign. Each screen needs a unique `id`, a `title`, a `frame` ({w,h} in pixels — default to the user's current panel size from `get_ui_viewport` so the mock fills their screen; use 360×720 for explicit mobile, 768×1024 for explicit tablet), and an array of `nodes`. Each node has a unique `id`, a `type` (one of: div, text, heading, Button, Input, Textarea, Badge, Separator, Image, Icon), absolute pixel coords (`x`,`y`,`width`,`height`) inside the frame, and optional `text` (label/placeholder), `className` (Tailwind for visuals using THEME tokens — `bg-card`, `text-muted-foreground`, etc.; layout-affecting classes are ignored, coords win), `style` (React inline-style object — use this for colors outside the app's theme palette like exact brand hex, gradients, and custom shadows; arbitrary-value Tailwind classes like `bg-[#hex]` do NOT work in `className` because the JIT only scans source files at build time, so off-theme color fidelity must come through `style`), and `props` (component-specific: Button/Badge `variant`, Input/Textarea `placeholder`, Image `src`, Icon `iconName` from lucide-react, heading `level` 1|2|3). Prefer `add_ui_screen` when extending an existing flow.",
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
        "Appends one screen to the existing UI mock without disturbing other screens. Use this when iterating on a flow (auth → onboarding → dashboard) or adding a variant alongside existing work. The `screen` shape matches one element of `spec.screens` in `set_ui_mock`. Call `get_ui_mock` first if you need to align the new screen with existing frame sizes or naming conventions; for a brand-new flow, default the frame to the user's current panel size from `get_ui_viewport` (use 360×720 for explicit mobile, 768×1024 for explicit tablet).",
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

  // iOS build / install / launch tools. Available regardless of whether the
  // workspace contains an Xcode project — `ios_status` returns `project.kind:
  // 'none'` if not, and the chat brain bails out gracefully in that case.

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
        const projectStatus = getIosProject();
        if (projectStatus.kind === 'none') {
          return iosBuildErrorResult(
            'detect',
            'no Xcode project detected in this workspace (need a *.xcodeproj or *.xcworkspace at depth ≤ 3)',
          );
        }
        if (projectStatus.kind === 'error') {
          return iosBuildErrorResult('detect', projectStatus.message);
        }
        if (projectStatus.kind === 'ambiguous' && !scheme) {
          return iosBuildErrorResult(
            'detect',
            'multiple Xcode projects detected; pass an explicit `scheme` matching one of the candidates (call `ios_status` to see them)',
          );
        }

        // Resolve the project to build. For ambiguous, find the candidate(s)
        // whose schemes include the requested scheme. Two projects can share
        // a scheme name (common: a generic `App` scheme in both an old and
        // new project, or a tooling project alongside the main one) — in
        // that case pick-first would silently build the wrong codebase, so
        // we error and ask the user to disambiguate by renaming.
        let project;
        if (projectStatus.kind === 'detected') {
          project = projectStatus.project;
        } else {
          const matches = projectStatus.candidates.filter((c) =>
            c.schemes.includes(scheme!),
          );
          if (matches.length === 0) {
            return iosBuildErrorResult(
              'detect',
              `scheme "${scheme}" not found in any detected Xcode project`,
            );
          }
          if (matches.length > 1) {
            const paths = matches
              .map((m) => m.projectPath)
              .join(', ');
            return iosBuildErrorResult(
              'detect',
              `scheme "${scheme}" matches multiple Xcode projects (${paths}); rename the scheme in one of them or remove the unwanted project from the workspace to disambiguate`,
            );
          }
          const match = matches[0];
          project = {
            projectPath: match.projectPath,
            projectKind: match.projectKind,
            scheme: scheme!,
            bundleId: null,
            configurations: ['Debug', 'Release'],
          };
        }

        // Resolve the device. If the caller passed a udid, use it. Otherwise
        // prefer the simulator serve-sim is showing; fall back to the first
        // booted device.
        let resolvedUdid = udid ?? null;
        if (!resolvedUdid) {
          const sim = getSimStatus();
          if (sim.phase === 'ready') {
            resolvedUdid = await readActiveDeviceFromServeSim(sim.url);
          }
        }
        if (!resolvedUdid) {
          const booted = await listBootedDevices();
          if (booted.length > 0) resolvedUdid = booted[0].udid;
        }
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
        let resolvedUdid = udid ?? null;
        if (!resolvedUdid) {
          const sim = getSimStatus();
          if (sim.phase === 'ready') {
            resolvedUdid = await readActiveDeviceFromServeSim(sim.url);
          }
        }
        if (!resolvedUdid) {
          const booted = await listBootedDevices();
          if (booted.length > 0) resolvedUdid = booted[0].udid;
        }
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
        // Surface validator rejections structurally so the model doesn't
        // mistake them for "no entries in the window."
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
            allowedHosts: ['localhost', '127.0.0.1', `localhost:${process.env.PORT ?? '3000'}`, `127.0.0.1:${process.env.PORT ?? '3000'}`],
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
