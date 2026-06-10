// Export & Run: deterministic codegen spliced into the user's own SwiftUI
// sources → incremental xcodebuild → simctl install → launch. POST kicks it
// off (fire-and-forget, 202); the browser polls GET for the phase. All state
// lives on a globalThis slot (see iosExport.ts) so the route graph and the
// server graph agree.
//
// The POST body may carry the browser's CURRENT `spec`: the canvas debounces
// its snapshots 250ms, so without this an element added just before the
// click would miss the export. The spec is adopted into the live cache (same
// validation + merge policy as a WS snapshot frame) before the run starts.

import {
  getExportRunState,
  isExportRunActive,
  runExportAndRun,
} from '@/server/iosExport';
import { getHook } from '@/server/serverHooks';
import { getWorkspaceOrNull } from '@/server/workspace';

export const runtime = 'nodejs';

type ExportRunBody = {
  scheme?: unknown;
  udid?: unknown;
  configuration?: unknown;
  spec?: unknown;
};

export async function GET() {
  return Response.json(getExportRunState());
}

export async function POST(request: Request) {
  if (getWorkspaceOrNull() == null) {
    return Response.json(
      { started: false, reason: 'no workspace selected' },
      { status: 409 },
    );
  }
  if (isExportRunActive()) {
    return Response.json(
      { started: false, reason: 'an export is already running', state: getExportRunState() },
      { status: 409 },
    );
  }

  let body: ExportRunBody = {};
  try {
    const raw = await request.text();
    if (raw) body = JSON.parse(raw) as ExportRunBody;
  } catch {
    return Response.json(
      { started: false, reason: 'request body is not JSON' },
      { status: 400 },
    );
  }

  if (body.spec !== undefined) {
    const adopt = getHook('adoptUiSnapshot');
    const adopted = adopt?.(body.spec);
    if (adopted && !adopted.ok) {
      return Response.json(
        { started: false, reason: `invalid spec: ${adopted.error}` },
        { status: 400 },
      );
    }
  }

  void runExportAndRun({
    scheme: typeof body.scheme === 'string' ? body.scheme : undefined,
    udid: typeof body.udid === 'string' ? body.udid : undefined,
    configuration:
      body.configuration === 'Debug' || body.configuration === 'Release'
        ? body.configuration
        : undefined,
  }).catch((err) => {
    console.error('[export-run] crashed', err);
  });

  return Response.json({ started: true }, { status: 202 });
}
