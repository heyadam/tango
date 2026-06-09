// Kick the preview-host build/install/launch. Fire-and-forget — the browser
// polls /api/preview/status for the phase.

import {
  getPreviewHostStatus,
  isPreviewHostBusy,
  startPreviewHost,
} from '@/server/previewHost';

export const runtime = 'nodejs';

export async function POST(request: Request) {
  if (isPreviewHostBusy()) {
    return Response.json(
      { started: false, reason: 'preview host is already starting', status: getPreviewHostStatus() },
      { status: 409 },
    );
  }

  let udid: string | undefined;
  try {
    const raw = await request.text();
    if (raw) {
      const body = JSON.parse(raw) as { udid?: unknown };
      if (typeof body.udid === 'string') udid = body.udid;
    }
  } catch {
    return Response.json(
      { started: false, reason: 'request body is not JSON' },
      { status: 400 },
    );
  }

  void startPreviewHost({ udid }).catch((err) => {
    console.error('[preview] start crashed', err);
  });

  return Response.json({ started: true }, { status: 202 });
}
