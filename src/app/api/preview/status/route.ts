import { getPreviewHostStatus } from '@/server/previewHost';

export const runtime = 'nodejs';

export async function GET() {
  return Response.json(getPreviewHostStatus());
}
