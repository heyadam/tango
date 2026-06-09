// The prompt the "Import from code" button submits to the terminal agent.
// Kept here (not inline in UIPanel) so the wording is reviewable and testable
// as data. The heavy lifting — the SwiftUI → UINode mapping — lives in the
// generated `tango-ui-import` skill (src/server/workspace.ts), which the
// prompt points at.

export const IMPORT_PROMPT = [
  "Import this workspace's SwiftUI screens into the tango design canvas.",
  'Follow the tango-ui-import skill (.claude/skills/tango-ui-import/SKILL.md):',
  'find the screen-level SwiftUI views (skip any TangoGenerated/ folder —',
  "that is tango's generated output, not a source of truth), translate each",
  'into a design screen, and write them with set_ui_mock / add_ui_screen.',
  'Import is read-only on the Swift side — do not edit any .swift files.',
].join(' ');
