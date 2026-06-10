// Fast import: SwiftUI sources → design screens via the direct-API engine in
// src/server/uiImport.ts. POST kicks it off (fire-and-forget, 202); the
// browser polls GET for progress. State lives on a globalThis slot so the
// route graph and the server graph agree — same pattern as Export & Run.
//
// POST with a JSON body `{ file, screenId }` runs a SCOPED re-import instead:
// refresh one screen from its linked source file (the chip's refresh action).

import {
  getUiImportState,
  isUiImportActive,
  runUiImport,
  type UiImportScope,
} from '@/server/uiImport';
import { getWorkspaceOrNull } from '@/server/workspace';

export const runtime = 'nodejs';

export async function GET() {
  return Response.json(getUiImportState());
}

export async function POST(request: Request) {
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

  // Optional scope body. A bare POST (no/empty body) = full workspace import.
  let scope: UiImportScope | undefined;
  try {
    const body = (await request.json()) as {
      file?: unknown;
      screenId?: unknown;
    };
    if (typeof body.file === 'string' && typeof body.screenId === 'string') {
      scope = { file: body.file, screenId: body.screenId };
    }
  } catch {
    // no JSON body — full import
  }

  void runUiImport(undefined, scope).catch((err) => {
    console.error('[ui-import] crashed', err);
  });

  return Response.json({ started: true }, { status: 202 });
}
