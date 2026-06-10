// Pure helpers behind the layers tree (UILayersPanel): row building (screen →
// group blocks → nodes, top-of-z first) and the drag-drop index math.
// Extracted so the fiddly parts — reverse-z display order, group blocks
// anchored at their topmost member, index shifts when the dragged node sits
// below the reference — are unit-testable away from the DOM.

import type { UINode, UIScreen } from './uiMockProtocol';

// One displayed row: either an ungrouped node or a group block (the group's
// members render nested under it). Blocks sit at their topmost member's z.
// Nodes tagged with a group id missing from the registry render as plain
// rows (the ops prune those tags, but a hand-edited design.json could carry
// them — never let a stale tag hide a node from the tree).
export type TreeRow =
  | { kind: 'node'; node: UINode }
  | { kind: 'group'; id: string; name: string; members: UINode[] };

export function buildRows(screen: UIScreen): TreeRow[] {
  const rows: TreeRow[] = [];
  const seen = new Set<string>();
  const names = new Map((screen.groups ?? []).map((g) => [g.id, g.name]));
  for (const node of [...screen.nodes].reverse()) {
    if (node.group && names.has(node.group)) {
      if (seen.has(node.group)) continue;
      seen.add(node.group);
      rows.push({
        kind: 'group',
        id: node.group,
        name: names.get(node.group)!,
        members: [...screen.nodes]
          .reverse()
          .filter((n) => n.group === node.group),
      });
    } else {
      rows.push({ kind: 'node', node });
    }
  }
  return rows;
}

// z-index (in the array AFTER the dragged node is removed) for a drop
// relative to a reference node. 'above' in the displayed (reverse-z) list =
// higher z = one past the reference; 'below' = take the reference's place.
export function dropIndexFor(
  screen: UIScreen,
  refNodeId: string,
  edge: 'above' | 'below',
  draggedId: string,
): number {
  const iRef = screen.nodes.findIndex((n) => n.id === refNodeId);
  const iDragged = screen.nodes.findIndex((n) => n.id === draggedId);
  const afterRemoval = iRef - (iDragged !== -1 && iDragged < iRef ? 1 : 0);
  return edge === 'above' ? afterRemoval + 1 : afterRemoval;
}
