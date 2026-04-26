// Wire protocol for /ws/canvas. The browser ships full snapshots up; the
// server pushes `set` (full replace) and `patch` (append) frames down, and
// requests rendered images via the `screenshot_request` round-trip. Imported
// by canvasBridge.ts (server) and SketchPanel.tsx (browser) so both sides
// agree on field names.

export type CanvasElement = Record<string, unknown>;
export type CanvasAppState = Record<string, unknown>;
export type CanvasFiles = Record<string, unknown>;

export type SnapshotMsg = {
  type: 'snapshot';
  elements?: CanvasElement[];
  appState?: CanvasAppState;
  files?: CanvasFiles;
};

export type ScreenshotResultMsg = {
  type: 'screenshot_result';
  requestId: string;
  mime?: string;
  data?: string;
  error?: string;
};

export type ServerSetMsg = {
  type: 'set';
  elements: CanvasElement[];
  appState: CanvasAppState;
  files: CanvasFiles;
};

export type ServerPatchMsg = {
  type: 'patch';
  mode: 'append';
  elements: CanvasElement[];
};

export type ScreenshotOpts = {
  mime?: string;
  quality?: number;
  maxDim?: number;
};

export type ScreenshotRequestMsg = {
  type: 'screenshot_request';
  requestId: string;
  opts?: ScreenshotOpts;
};

export type ScreenshotResult = { mime: string; data: string };

export type CanvasClientMsg = SnapshotMsg | ScreenshotResultMsg;
export type CanvasServerMsg = ServerSetMsg | ServerPatchMsg | ScreenshotRequestMsg;
