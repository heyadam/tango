// Single source of truth for the workspace mode literal union. The top-bar
// tablist switches it, page.tsx threads it down, and LeftPanel reads it to
// pick which left-pane component to mount. Adding a new mode is a one-file
// change here plus wiring up its rendering in LeftPanel.

export type WorkspaceMode = 'sketch' | 'moodboard' | 'brand' | 'ui';
