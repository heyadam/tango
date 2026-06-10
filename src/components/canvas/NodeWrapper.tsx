'use client';

// One canvas node: the absolutely-positioned wrapper div (drag/resize target,
// selection ring, pulse) around the UIMockNode renderer. Extracted from
// UIMockCanvas so the memo contract is visible in isolation.

import {
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type RefObject,
  memo,
  useCallback,
} from 'react';
import UIMockNode from '../UIMockNode';
import type { UINode } from '@/lib/uiMockProtocol';
import { cn } from '@/lib/utils';

// Memoized: with uiMockOps preserving node identity for untouched nodes and
// every callback prop useCallback-stable in the parent, a drag/selection
// change re-renders only the affected nodes instead of the whole canvas.
const NodeWrapper = memo(function NodeWrapper({
  node,
  isSelected,
  isPulsing,
  isEditing,
  refsMap,
  onPointerSelect,
  onStartEditing,
  onCommitText,
  onEndEdit,
}: {
  node: UINode;
  isSelected: boolean;
  isPulsing: boolean;
  isEditing: boolean;
  refsMap: RefObject<Map<string, HTMLDivElement>>;
  onPointerSelect: (id: string, mode: 'replace' | 'additive' | 'deep') => void;
  onStartEditing: (id: string) => void;
  onCommitText: (id: string, text: string) => void;
  onEndEdit: () => void;
}) {
  // Callback ref keeps the refs map in sync with the live DOM. We register on
  // mount and unregister on unmount; React calls the callback with `null` on
  // unmount so the cleanup is automatic.
  const setRef = useCallback(
    (el: HTMLDivElement | null) => {
      const map = refsMap.current;
      if (!map) return;
      if (el) {
        map.set(node.id, el);
      } else {
        map.delete(node.id);
      }
    },
    [node.id, refsMap],
  );

  const onPointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      // Don't kick selection while the user is editing text.
      if (isEditing) return;
      // Stop the canvas-level click-to-deselect from firing.
      e.stopPropagation();
      // Figma muscle memory: Shift adds, Cmd/Ctrl deep-selects past a group,
      // plain click selects the node's whole group (resolved in the parent).
      const mode = e.shiftKey ? 'additive' : e.metaKey || e.ctrlKey ? 'deep' : 'replace';
      onPointerSelect(node.id, mode);
    },
    [isEditing, node.id, onPointerSelect],
  );

  const onDoubleClick = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      if (!isTextual(node)) return;
      e.stopPropagation();
      onStartEditing(node.id);
    },
    [node, onStartEditing],
  );

  const commitText = useCallback(
    (text: string) => onCommitText(node.id, text),
    [node.id, onCommitText],
  );

  const style: CSSProperties = {
    position: 'absolute',
    left: node.x,
    top: node.y,
    width: node.width,
    height: node.height,
  };

  return (
    <div
      ref={setRef}
      data-mock-id={node.id}
      className={cn(
        'box-border',
        isSelected && 'ring-1 ring-ring/50',
        isPulsing && 'outline outline-2 outline-primary/70',
      )}
      style={style}
      onPointerDown={onPointerDown}
      onDoubleClick={onDoubleClick}
    >
      <UIMockNode
        node={node}
        isEditing={isEditing}
        onCommitText={commitText}
        onEndEdit={onEndEdit}
      />
    </div>
  );
});

function isTextual(node: UINode): boolean {
  return (
    node.type === 'text' ||
    node.type === 'heading' ||
    node.type === 'Button' ||
    node.type === 'Badge'
  );
}

export default NodeWrapper;
