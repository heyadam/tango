import { getSimStatus } from '@/server/sim';

export async function GET() {
  return Response.json(getSimStatus());
}
