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
// A draggedId that lives on ANOTHER screen (cross-screen drag) is simply not
// found here (iDragged -1) → no removal adjustment, which is exactly right:
// removing the node from its source screen never shifts this screen's
// indices.
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

// Insertion index for a drop at the TOP of z (end of the array, after the
// dragged node is removed if it lives on this screen). Used for drops on a
// screen header / empty screen area.
export function endDropIndex(screen: UIScreen, draggedId: string): number {
  return (
    screen.nodes.length - (screen.nodes.some((n) => n.id === draggedId) ? 1 : 0)
  );
}

// Group-block variant of endDropIndex: end-of-z index after ALL of the
// dragged group's members are removed from this screen. Group ids are only
// unique PER SCREEN, so matching on the id alone isn't enough — members are
// only being removed when this screen IS the drag's source screen
// (`fromScreenId`). On a cross-screen drag, a same-id group here is the
// target's own distinct group and nothing is removed.
export function groupEndDropIndex(
  screen: UIScreen,
  draggedGroupId: string,
  fromScreenId: string,
): number {
  if (screen.id !== fromScreenId) return screen.nodes.length;
  return (
    screen.nodes.length -
    screen.nodes.filter((n) => n.group === draggedGroupId).length
  );
}

// Insertion index for a GROUP BLOCK dropped relative to a reference node row,
// in the array AFTER all the group's members are removed. Returns null when
// the reference isn't on this screen, or when this screen is the drag's
// SOURCE screen (`fromScreenId`) and the reference is a member of the dragged
// group (the panel ignores such drops). Group ids are only unique PER SCREEN:
// on a cross-screen drag nothing is being removed here, so removedBelow is 0
// and a reference tagged with the SAME id (the target's own distinct group)
// is a legal reference — though the panel never offers grouped rows as
// group-drop refs anyway.
export function groupDropIndexFor(
  screen: UIScreen,
  refNodeId: string,
  edge: 'above' | 'below',
  draggedGroupId: string,
  fromScreenId: string,
): number | null {
  const iRef = screen.nodes.findIndex((n) => n.id === refNodeId);
  if (iRef === -1) return null;
  const sameScreen = screen.id === fromScreenId;
  if (sameScreen && screen.nodes[iRef].group === draggedGroupId) return null;
  const removedBelow = sameScreen
    ? screen.nodes.filter((n, i) => i < iRef && n.group === draggedGroupId)
        .length
    : 0;
  const afterRemoval = iRef - removedBelow;
  return edge === 'above' ? afterRemoval + 1 : afterRemoval;
}
