import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { getWorkspaceOrNull } from '@/server/workspace';
import { appendEvent } from '@/server/memory';

const MAX_CAPTION_LEN = 240;

export async function POST(request: Request) {
  const workspace = getWorkspaceOrNull();
  if (!workspace) {
    return Response.json(
      { error: 'no workspace selected' },
      { status: 409 },
    );
  }

  const url = new URL(request.url);
  const rawCaption = url.searchParams.get('caption');
  const caption =
    rawCaption && rawCaption.trim()
      ? rawCaption.trim().slice(0, MAX_CAPTION_LEN)
      : undefined;

  const buf = Buffer.from(await request.arrayBuffer());
  if (buf.byteLength === 0) {
    return Response.json({ error: 'empty body' }, { status: 400 });
  }

  const dir = path.join(workspace, 'design-scratch');
  await fs.mkdir(dir, { recursive: true });

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const suffix = randomBytes(2).toString('hex');
  const filename = `${stamp}-${suffix}.png`;
  const absPath = path.join(dir, filename);
  await fs.writeFile(absPath, buf);

  const relPath = `design-scratch/${filename}`;

  // Fire-and-forget: appendEvent enqueues internally and never throws.
  appendEvent({ type: 'snapshot', relPath, caption });

  // relPath is resolved from the workspace dir, which is also where the
  // in-app terminal lands and where claude reads from — so a bare
  // "design-scratch/foo.png" works.
  return Response.json({
    relPath,
    absPath,
  });
}
