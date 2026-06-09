// Drive the booted iOS simulator that serve-sim is streaming: tap, swipe,
// hardware buttons, text entry, rotation, plus an accessibility-tree read for
// aiming. Backs the `ios_*` control MCP tools.
//
// Integration channel: serve-sim's CLI subcommands (`serve-sim tap/gesture/
// button/type/rotate -d <udid>`) — its stable, documented public surface —
// invoked via `runCommand`. Coordinates are normalized 0..1 (serve-sim's own
// convention). The accessibility tree comes from serve-sim's `/.sim/ax` SSE
// endpoint; we read a single snapshot off it and disconnect.
//
// Pure helpers (validateNormalized / isValidOrientation / isValidButtonName /
// gestureFrame / axCenterNorm / firstSseJson / toInspectResult) are unit-tested
// in iosSimControl.test.ts; everything that shells out or fetches is exercised
// manually against a booted simulator.

import { runCommand } from './iosBuild';

// serve-sim control commands are quick round-trips to a local daemon; a slow
// one means the daemon is wedged, so fail fast rather than hang the tool call.
const SERVE_SIM_TIMEOUT_MS = 8_000;
// The ax streamer polls the helper every ~500ms; a first snapshot usually
// lands well within this, but accessibility can take a beat to warm up.
const AX_TIMEOUT_MS = 6_000;

// ---------------------------------------------------------------------------
// Accessibility-tree types (mirrors serve-sim's normalized AxSnapshot shape;
// frame coords are in device points, with `screen` giving the bounds).
// ---------------------------------------------------------------------------

export type AxRect = { x: number; y: number; width: number; height: number };

export type AxElement = {
  id: string;
  path: string;
  label: string;
  value: string;
  role: string;
  type: string;
  enabled: boolean;
  frame: AxRect;
};

export type AxSnapshot = {
  screen: { width: number; height: number };
  elements: AxElement[];
  errors?: string[];
};

export type InspectElement = AxElement & {
  // 0..1 center of the element, ready to hand straight to `ios_tap`.
  centerNorm: { x: number; y: number };
};

export type InspectResult = {
  screen: { width: number; height: number };
  elements: InspectElement[];
  errors?: string[];
};

export type ControlResult = {
  ok: boolean;
  message: string;
  durationMs: number;
};

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

export const ROTATE_ORIENTATIONS = [
  'portrait',
  'portrait_upside_down',
  'landscape_left',
  'landscape_right',
] as const;

export type Orientation = (typeof ROTATE_ORIENTATIONS)[number];

export function isValidOrientation(s: string): s is Orientation {
  return (ROTATE_ORIENTATIONS as readonly string[]).includes(s);
}

// serve-sim passes the button name through to the simulator helper, which is
// the authority on the supported set ('home' is the documented default;
// 'lock' / 'siri' / 'side' are common). We only guard the format so a junk
// value can't reach the CLI as an unexpected flag-shaped token.
export function isValidButtonName(s: string): boolean {
  return /^[a-z][a-z-]{0,31}$/.test(s);
}

export function validateNormalized(
  x: number,
  y: number,
): { ok: true } | { ok: false; reason: string } {
  for (const [name, v] of [
    ['x', x],
    ['y', y],
  ] as const) {
    if (typeof v !== 'number' || !Number.isFinite(v)) {
      return { ok: false, reason: `${name} must be a finite number` };
    }
    if (v < 0 || v > 1) {
      return {
        ok: false,
        reason: `${name}=${v} is out of range — coordinates are normalized 0..1 (0,0 top-left, 1,1 bottom-right)`,
      };
    }
  }
  return { ok: true };
}

// JSON frame for `serve-sim gesture '<json>'`, e.g. {"type":"begin","x":0.5,"y":0.5}.
export function gestureFrame(type: string, x: number, y: number): string {
  return JSON.stringify({ type, x, y });
}

function clamp01(n: number): number {
  if (!Number.isFinite(n)) return 0;
  return n < 0 ? 0 : n > 1 ? 1 : n;
}

// Normalized (0..1) center of an ax element's frame, clamped to screen bounds.
export function axCenterNorm(
  frame: AxRect,
  screen: { width: number; height: number },
): { x: number; y: number } {
  const w = screen.width > 0 ? screen.width : 1;
  const h = screen.height > 0 ? screen.height : 1;
  return {
    x: clamp01((frame.x + frame.width / 2) / w),
    y: clamp01((frame.y + frame.height / 2) / h),
  };
}

// Extract the first complete SSE `data:` payload that parses as a JSON object
// from an accumulated stream buffer. Skips comment lines (`:` heartbeats) and
// ignores the trailing partial event (no `\n\n` terminator yet) so we never
// JSON.parse a half-arrived chunk. Returns null until a full event is present.
export function firstSseJson(buffer: string): unknown | null {
  const segments = buffer.split('\n\n');
  // The final segment is only complete if the buffer ended on an event
  // boundary; otherwise it's still being received.
  const complete = buffer.endsWith('\n\n') ? segments : segments.slice(0, -1);
  for (const evt of complete) {
    const data = evt
      .split('\n')
      .filter((l) => l.startsWith('data:'))
      .map((l) => l.slice(5).trim())
      .join('\n');
    if (!data) continue;
    try {
      const parsed = JSON.parse(data);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch {
      // Non-JSON or partial — keep scanning later events.
    }
  }
  return null;
}

function isAxSnapshot(v: unknown): v is AxSnapshot {
  if (!v || typeof v !== 'object') return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.screen === 'object' &&
    o.screen !== null &&
    Array.isArray(o.elements)
  );
}

// Attach a normalized center to every element so the model can pass it straight
// to `ios_tap`. Pure — the impure SSE read is `fetchAxSnapshot`.
export function toInspectResult(snapshot: AxSnapshot): InspectResult {
  return {
    screen: snapshot.screen,
    elements: snapshot.elements.map((el) => ({
      ...el,
      centerNorm: axCenterNorm(el.frame, snapshot.screen),
    })),
    ...(snapshot.errors && snapshot.errors.length > 0
      ? { errors: snapshot.errors }
      : {}),
  };
}

// ---------------------------------------------------------------------------
// serve-sim CLI runner + control verbs
// ---------------------------------------------------------------------------

async function serveSim(
  verb: string,
  args: string[],
  udid: string,
  opts: { input?: string } = {},
): Promise<ControlResult> {
  const r = await runCommand(
    'npx',
    ['serve-sim', verb, ...args, '-d', udid],
    { timeoutMs: SERVE_SIM_TIMEOUT_MS, input: opts.input },
  );
  if (r.exitCode === 0) {
    return {
      ok: true,
      message: (r.stdout || r.stderr).trim().slice(0, 500),
      durationMs: r.durationMs,
    };
  }
  const why = r.timedOut
    ? `serve-sim ${verb} timed out after ${(r.durationMs / 1000).toFixed(0)}s`
    : (r.stderr || r.stdout).trim().slice(0, 500) ||
      `serve-sim ${verb} exited with code ${r.exitCode}`;
  return { ok: false, message: why, durationMs: r.durationMs };
}

export function iosTap(
  udid: string,
  x: number,
  y: number,
): Promise<ControlResult> {
  return serveSim('tap', [String(x), String(y)], udid);
}

// Swipe / drag. serve-sim's CLI sends one touch frame per invocation, so a drag
// is a `begin` frame at the start point followed by an `end` frame at the
// destination. Each call is its own short-lived WS connection — fine for
// discrete swipes, but very fast continuous drags may register imperfectly
// (accepted limitation; a single-socket WS send is the future upgrade).
export async function iosGesture(
  udid: string,
  fromX: number,
  fromY: number,
  toX: number,
  toY: number,
): Promise<ControlResult> {
  const begin = await serveSim('gesture', [gestureFrame('begin', fromX, fromY)], udid);
  if (!begin.ok) return begin;
  const end = await serveSim('gesture', [gestureFrame('end', toX, toY)], udid);
  if (!end.ok) return end;
  return {
    ok: true,
    message: `swiped (${fromX}, ${fromY}) → (${toX}, ${toY})`,
    durationMs: begin.durationMs + end.durationMs,
  };
}

export function iosButton(udid: string, name: string): Promise<ControlResult> {
  return serveSim('button', [name], udid);
}

// Text via stdin (`--stdin`) rather than argv so arbitrary content — leading
// dashes, whitespace runs, newlines — can't be mangled into option flags or
// re-split by the shell. US keyboard only (serve-sim limitation).
export function iosType(udid: string, text: string): Promise<ControlResult> {
  return serveSim('type', ['--stdin'], udid, { input: text });
}

export function iosRotate(
  udid: string,
  orientation: Orientation,
): Promise<ControlResult> {
  return serveSim('rotate', [orientation], udid);
}

// Open one ax SSE connection, read the first event, then disconnect. Returns
// 'not-found' on a 404 (wrong base path) so the caller can try another; throws
// on any other failure.
async function readAxOnce(
  url: string,
  timeoutMs: number,
): Promise<AxSnapshot | 'not-found'> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: { accept: 'text/event-stream' },
    });
    if (res.status === 404) return 'not-found';
    if (!res.ok || !res.body) {
      throw new Error(`serve-sim /ax returned HTTP ${res.status}`);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parsed = firstSseJson(buffer);
      if (isAxSnapshot(parsed)) return parsed;
    }
    throw new Error('serve-sim /ax stream ended before a snapshot arrived');
  } finally {
    clearTimeout(timer);
    // One-shot read: tear down the SSE connection regardless of outcome.
    controller.abort();
  }
}

// Read a single accessibility snapshot off serve-sim's ax SSE stream, then
// disconnect. Returns the first event the stream emits (which may carry an
// `errors` array, e.g. "Accessibility unavailable", that the caller surfaces).
// The standalone `npx serve-sim` preview mounts ax at `/ax`; an embedded
// middleware mount uses `/.sim/ax`. Try root first, fall back on a 404.
export async function fetchAxSnapshot(
  simUrl: string,
  udid: string,
  opts: { timeoutMs?: number } = {},
): Promise<AxSnapshot> {
  const timeoutMs = opts.timeoutMs ?? AX_TIMEOUT_MS;
  const query = `/ax?device=${encodeURIComponent(udid)}`;
  const root = await readAxOnce(`${simUrl}${query}`, timeoutMs);
  if (root !== 'not-found') return root;
  const nested = await readAxOnce(`${simUrl}/.sim${query}`, timeoutMs);
  if (nested !== 'not-found') return nested;
  throw new Error(
    'serve-sim exposes no /ax endpoint (tried /ax and /.sim/ax) — is a device being streamed?',
  );
}
