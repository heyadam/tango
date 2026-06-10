// Pure prompt builders for canvas-originated agent tasks (the AI popout).
// Prompts are id-scoped — the agent calls get_ui_mock to read fresh state,
// never receives embedded spec JSON. The safety phrases that keep variation
// generation non-destructive are pinned in agentTaskPrompts.test.ts; do not
// reword them casually. Browser-safe and side-effect free.

import type { AgentTask } from './terminalBus';

export function buildVariationsPrompt(scope: AgentTask['scope']): string {
  // Node scope varies the selected element(s), not the screen: 3 variants of
  // the selection laid out in ONE new comparison screen. Whole-screen
  // variations are the screen-scope (or empty-selection) behavior below.
  if (scope.kind === 'nodes' && scope.nodeIds?.length) {
    return (
      `Call get_ui_mock and read screen "${scope.screenId}" ("${scope.screenTitle}"). The user selected these element node(s): ${scope.nodeIds.join(', ')}.\n` +
      'Create exactly 3 divergent variations of the SELECTED ELEMENT(S) ONLY — not the whole screen — laid out together in ONE new comparison screen (a single add_ui_screen call).\n' +
      'Hard rules:\n' +
      '- NEVER call set_ui_mock or clear_ui_mock, and never modify the original screen or any other existing screen.\n' +
      `- The new screen id must be fresh and globally unique: use "${scope.screenId}-el-v1" (pick a different suffix if taken). Title it "${scope.screenTitle} · element variations". Copy the original frame {w,h} exactly.\n` +
      "- Treat the selection as one unit. Each variation is a fresh copy of just that unit — keep each unit's internal relative positions coherent, and space the 3 units out evenly (stacked vertically, or a grid if the unit is wide).\n" +
      '- Every node id must be fresh and globally unique across the whole spec — prefix every node id with the new screen id.\n' +
      '- Do not reproduce the rest of the original screen, and do not set sourceFile on the new screen.\n' +
      '- Diverge genuinely in layout, hierarchy, styling, and copy — not just color swaps.\n' +
      'Finish with one short line per variation describing its idea.'
    );
  }
  return (
    `Call get_ui_mock and read screen "${scope.screenId}" ("${scope.screenTitle}").\n` +
    'Create exactly 3 divergent variations of it as NEW screens. For speed, fan out: launch 3 subagents with the Task tool IN PARALLEL — all three Task calls in a single message — one subagent per variation. Assign each subagent a distinct divergence direction plus its exact screen id and title from the rules below, and repeat the hard rules verbatim in its instructions; each subagent calls get_ui_mock itself and then makes exactly one add_ui_screen call. If the Task tool is unavailable, do them sequentially yourself — one add_ui_screen call per variation, so they stream onto the canvas one by one.\n' +
    'Hard rules:\n' +
    '- NEVER call set_ui_mock or clear_ui_mock, and never modify the original screen or any other existing screen.\n' +
    `- Every new screen id and every node id must be fresh and globally unique across the whole spec. Use "${scope.screenId}-v1", "${scope.screenId}-v2", "${scope.screenId}-v3" (pick a different suffix if one is taken) and prefix every node id with its new screen id.\n` +
    `- Copy the original frame {w,h} exactly. Title the screens "${scope.screenTitle} · v1", "· v2", "· v3".\n` +
    "- Do not copy the original screen's sourceFile onto the variations.\n" +
    '- Diverge genuinely in layout, hierarchy, and styling — not just color swaps.\n' +
    'Finish with one short line per variation describing its idea.'
  );
}

export function buildCustomPrompt(scope: AgentTask['scope'], userText: string): string {
  const context =
    scope.kind === 'nodes' && scope.nodeIds?.length
      ? `The user selected node(s) ${scope.nodeIds.join(', ')} in screen "${scope.screenId}" ("${scope.screenTitle}").`
      : `In screen "${scope.screenId}" ("${scope.screenTitle}"):`;
  return (
    `${context}\n${userText.trim()}\n\n` +
    'Call get_ui_mock first to read the live state. For in-place edits use the node-level tools (update_ui_node / add_ui_nodes / remove_ui_node / reorder_ui_node) so other nodes survive; for new screens use add_ui_screen with fresh globally-unique ids. Avoid set_ui_mock — it replaces the whole spec.'
  );
}

export function taskLabel(
  scope: AgentTask['scope'],
  kind: 'variations' | 'custom',
  userText?: string,
): string {
  if (kind === 'variations') {
    return scope.kind === 'nodes' && scope.nodeIds?.length
      ? `3 element variations · ${scope.screenTitle}`
      : `3 variations · ${scope.screenTitle}`;
  }
  const firstLine = (userText ?? '').trim().split('\n')[0] ?? '';
  const head = firstLine.length > 40 ? `${firstLine.slice(0, 40)}…` : firstLine;
  return `${head} · ${scope.screenTitle}`;
}

// Chip label → textarea prefill (never instant-fire) for the popout presets.
export const PRESET_PREFILLS: {
  screen: Record<string, string>;
  nodes: Record<string, string>;
} = {
  screen: {
    Restyle:
      'Restyle this screen with a different visual treatment — keep the content and layout intent',
    Simplify: 'Simplify this screen — remove visual noise and redundant elements',
    Rearrange: "Rearrange this screen's layout for better hierarchy",
  },
  nodes: {
    Restyle:
      'Restyle this screen with a different visual treatment — keep the content and layout intent',
    'Polish copy': 'Rewrite the text of the selected elements to be tighter and clearer',
    Rearrange: "Rearrange this screen's layout for better hierarchy",
  },
};
