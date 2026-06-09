// Fast import: SwiftUI sources → design screens via the direct-API engine in
// src/server/uiImport.ts. POST kicks it off (fire-and-forget, 202); the
// browser polls GET for progress. State lives on a globalThis slot so the
// route graph and the server graph agree — same pattern as Export & Run.

import {
  getUiImportState,
  isUiImportActive,
  runUiImport,
} from '@/server/uiImport';
import { getWorkspaceOrNull } from '@/server/workspace';

export const runtime = 'nodejs';

export async function GET() {
  return Response.json(getUiImportState());
}

export async function POST() {
  if (getWorkspaceOrNull() == null) {
    return Response.json(
      { started: false, reason: 'no workspace selected' },
      { status: 409 },
    );
  }
  if (isUiImportActive()) {
    return Response.json(
      {
        started: false,
        reason: 'an import is already running',
        state: getUiImportState(),
      },
      { status: 409 },
    );
  }

  void runUiImport().catch((err) => {
    console.error('[ui-import] crashed', err);
  });

  return Response.json({ started: true }, { status: 202 });
}
