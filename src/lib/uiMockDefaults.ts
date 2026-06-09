// Default geometry + content for a freshly-added UI mock node, keyed by type.
// Used by the browser Add palette (UIAddPalette → UIMockCanvas) so a user can
// drop a sensible-looking element with one click, then drag/resize/edit it.
// The MCP `add_ui_nodes` tool does NOT use these — Claude supplies full node
// specs itself (it knows the schema), same as `set_ui_mock`.
//
// Sizes/text/props are aligned with how UIMockNode.tsx renders each type and
// with the "Default sizes" guidance in the tango-ui-mock SKILL.

import type { UINode, UINodeType } from './uiMockProtocol';

type NodeDefault = {
  width: number;
  height: number;
  text?: string;
  className?: string;
  props?: Record<string, unknown>;
};

export const NODE_DEFAULTS: Record<UINodeType, NodeDefault> = {
  div: { width: 200, height: 120 },
  text: { width: 160, height: 24, text: 'Text' },
  heading: { width: 280, height: 40, text: 'Heading', props: { level: 2 } },
  Button: { width: 120, height: 36, text: 'Button', props: { variant: 'default' } },
  Input: { width: 220, height: 36, props: { placeholder: 'Placeholder' } },
  Textarea: { width: 260, height: 96, props: { placeholder: 'Placeholder' } },
  Badge: { width: 72, height: 24, text: 'Badge', props: { variant: 'default' } },
  Separator: { width: 200, height: 16 },
  Image: { width: 160, height: 120 },
  Icon: { width: 40, height: 40, props: { iconName: 'Star' } },
};

// Human-readable label for each node type, shown in the Add palette.
export const NODE_LABELS: Record<UINodeType, string> = {
  div: 'Box',
  text: 'Text',
  heading: 'Heading',
  Button: 'Button',
  Input: 'Input',
  Textarea: 'Textarea',
  Badge: 'Badge',
  Separator: 'Separator',
  Image: 'Image',
  Icon: 'Icon',
};

// The order types appear in the Add palette.
export const NODE_TYPE_ORDER: UINodeType[] = [
  'heading',
  'text',
  'Button',
  'Input',
  'Textarea',
  'Badge',
  'div',
  'Separator',
  'Image',
  'Icon',
];

// Build a fresh node of `type` at (x, y) with default size/content and a
// unique id. Browser-only (uses crypto.randomUUID, available in the DOM).
export function makeNode(type: UINodeType, x: number, y: number): UINode {
  const def = NODE_DEFAULTS[type];
  return {
    id: `node-${crypto.randomUUID().slice(0, 8)}`,
    type,
    x: Math.round(x),
    y: Math.round(y),
    width: def.width,
    height: def.height,
    ...(def.text !== undefined ? { text: def.text } : {}),
    ...(def.className !== undefined ? { className: def.className } : {}),
    ...(def.props !== undefined ? { props: def.props } : {}),
  };
}
