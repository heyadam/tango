import path from 'node:path';
import { getWorkspaceOrNull, getWorkspaceSource } from '@/server/workspace';

export async function GET() {
  const p = getWorkspaceOrNull();
  return Response.json({
    path: p,
    name: p ? path.basename(p) : null,
    source: getWorkspaceSource(),
  });
}
