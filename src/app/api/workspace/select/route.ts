import path from 'node:path';
import { dryRunSetWorkspace, setWorkspace } from '@/server/workspaceState';
import { tangoPort } from '@/server/config';

type SelectBody = { path?: unknown; dryRun?: unknown };

function getPort(): number {
  // server.ts stashes the port we listened on into TANGO_PORT before any
  // route can run (see src/server/config.ts).
  return tangoPort();
}

export async function POST(request: Request) {
  let body: SelectBody;
  try {
    body = (await request.json()) as SelectBody;
  } catch {
    return Response.json(
      { ok: false, code: 'invalid_path', reason: 'request body is not JSON' },
      { status: 400 },
    );
  }

  if (typeof body.path !== 'string') {
    return Response.json(
      { ok: false, code: 'invalid_path', reason: 'path is required' },
      { status: 400 },
    );
  }

  const dryRun = body.dryRun === true;
  const result = dryRun
    ? await dryRunSetWorkspace(body.path)
    : await setWorkspace(getPort(), body.path);

  if (!result.ok) {
    if (result.code === 'env_locked') {
      return Response.json(result, { status: 423 });
    }
    if (result.code === 'invalid_path') {
      return Response.json(result, { status: 400 });
    }
    return Response.json(result, { status: 500 });
  }

  return Response.json({
    ...result,
    name: path.basename(result.path),
  });
}
