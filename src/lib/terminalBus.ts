type SendListener = (text: string) => void;
type OutputListener = (data: string) => void;

// A structured, canvas-originated agent request. Carries provenance (scope +
// label) that the plain text channel cannot: the mounted agent panel consumes
// the prompt, the page shell observes submission to auto-expand the sidebar.
export type AgentTask = {
  prompt: string;
  label: string;
  scope: {
    kind: 'screen' | 'nodes';
    screenId: string;
    screenTitle: string;
    nodeIds?: string[];
  };
};

// Presentational-only snapshot of whichever agent panel is mounted. Published
// by AgentPanel/Terminal, consumed for captions — never gates behavior beyond
// disabling send when nothing is connected.
export type AgentPanelState =
  | { kind: 'tango'; busy: boolean; connected: boolean }
  | { kind: 'pty'; agent: 'claude' | 'codex' }
  | { kind: 'none' };

type TaskListener = (task: AgentTask) => void;
type AgentStateListener = (state: AgentPanelState) => void;

const sendListeners = new Set<SendListener>();
const outputListeners = new Set<OutputListener>();
const taskListeners = new Set<TaskListener>();
const taskObservers = new Set<() => void>();
const agentStateListeners = new Set<AgentStateListener>();
let agentState: AgentPanelState = { kind: 'none' };

// All submit-shaped writes share one serial queue: each entry is its text
// write, the bare '\r' 120ms later, then a 150ms gap before the next entry.
// Without it, two programmatic submits inside the '\r' window interleave on
// the PTY byte stream (and fuse inside createSubmitBuffer) — e.g. a popout
// task drain racing the Send button.
const submitQueue: string[] = [];
let submitDraining = false;
function drainSubmitQueue(): void {
  const text = submitQueue.shift();
  if (text === undefined) {
    submitDraining = false;
    return;
  }
  submitDraining = true;
  for (const fn of sendListeners) fn(text);
  window.setTimeout(() => {
    for (const fn of sendListeners) fn('\r');
    window.setTimeout(drainSubmitQueue, 150);
  }, 120);
}

export const terminalBus = {
  // Public API for the rest of the app:

  sendToTerminal(text: string): void {
    for (const fn of sendListeners) fn(text);
  },

  submitToTerminal(text: string): void {
    submitQueue.push(text);
    if (!submitDraining) drainSubmitQueue();
  },

  onTerminalOutput(cb: OutputListener): () => void {
    outputListeners.add(cb);
    return () => outputListeners.delete(cb);
  },

  submitTask(task: AgentTask): void {
    for (const fn of taskListeners) fn(task);
    for (const fn of taskObservers) fn();
  },

  onTaskSubmitted(cb: () => void): () => void {
    taskObservers.add(cb);
    return () => taskObservers.delete(cb);
  },

  getAgentState(): AgentPanelState {
    return agentState;
  },

  onAgentState(cb: AgentStateListener): () => void {
    agentStateListeners.add(cb);
    return () => agentStateListeners.delete(cb);
  },

  // Wired by the Terminal component only:

  _onSend(cb: SendListener): () => void {
    sendListeners.add(cb);
    return () => sendListeners.delete(cb);
  },

  _emitOutput(data: string): void {
    for (const fn of outputListeners) fn(data);
  },

  // Wired by the mounted agent panel (AgentPanel or Terminal) only:

  _onTask(cb: TaskListener): () => void {
    taskListeners.add(cb);
    return () => taskListeners.delete(cb);
  },

  _setAgentState(state: AgentPanelState): void {
    agentState = state;
    for (const fn of agentStateListeners) fn(state);
  },
};

declare global {
  interface Window {
    __tangoBus?: typeof terminalBus;
  }
}

if (typeof window !== 'undefined' && process.env.NODE_ENV !== 'production') {
  window.__tangoBus = terminalBus;
}
