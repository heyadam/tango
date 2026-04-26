// Wire protocol for /ws/agent-cursor — server pushes commands, browser
// dispatches them via AgentCursorOverlay and replies to round-trip ones
// (currently only `inspect`). Imported by both sides so the contract can't
// drift between agentCursorBridge.ts and AgentCursorOverlay.tsx.

export type CursorMoveCmd = {
  type: 'move';
  selector?: string;
  x?: number;
  y?: number;
  durationMs?: number;
};

export type CursorClickCmd = {
  type: 'click';
  selector?: string;
  x?: number;
  y?: number;
  button?: 'left' | 'right';
};

export type CursorTypeCmd = {
  type: 'type';
  text: string;
  selector?: string;
};

export type TerminalTypeCmd = {
  type: 'terminal_type';
  text: string;
  submit?: boolean;
};

export type InspectCmd = {
  type: 'inspect';
  requestId: string;
  query?: string;
  selector?: string;
  limit?: number;
};

// Server → browser commands. The browser-only `inspect` command is included
// because AgentCursorOverlay handles it inline.
export type AgentCursorServerMsg =
  | CursorMoveCmd
  | CursorClickCmd
  | CursorTypeCmd
  | TerminalTypeCmd
  | InspectCmd;

// Server → browser commands that don't expect a reply. This is what
// pushCursorCommand accepts — the round-trip `inspect` goes through
// requestInspect instead.
export type AgentCommand =
  | CursorMoveCmd
  | CursorClickCmd
  | CursorTypeCmd
  | TerminalTypeCmd;

export type InteractiveElement = {
  role: string;
  name: string;
  text: string;
  rect: { x: number; y: number; width: number; height: number };
  center: { x: number; y: number };
  selector?: string;
  inViewport: boolean;
  disabled: boolean;
};

export type InspectResult = {
  total: number;
  returned: number;
  viewport: { width: number; height: number };
  elements: InteractiveElement[];
};

export type InspectResultMsg = {
  type: 'inspect_result';
  requestId: string;
  result?: InspectResult;
  error?: string;
};
