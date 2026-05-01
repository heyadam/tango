import { createContext } from 'react';

// LeftPanel renders one consolidated header with three regions: a left
// metadata slot, a centered mode-tab region, and a right action slot. The
// active mode panel (Sketch / Moodboard / UI) portals its toolbar nodes
// into the left and right slots so we end up with a single nav bar.
//
// `null` while the slot div hasn't mounted yet — consumers must guard
// before calling `createPortal`.
export const PanelHeaderLeftSlot = createContext<HTMLElement | null>(null);
export const PanelHeaderRightSlot = createContext<HTMLElement | null>(null);
