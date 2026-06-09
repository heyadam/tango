import {
  getTerminalAgent,
  setTerminalAgent,
} from '@/server/workspaceState';

export const runtime = 'nodejs';

type TerminalAgentBody = {
  agent?: unknown;
};

export async function GET() {
  return Response.json({ agent: getTerminalAgent() });
}

export async function POST(request: Request) {
  let body: TerminalAgentBody;
  try {
    body = (await request.json()) as TerminalAgentBody;
  } catch {
    return Response.json(
      {
        ok: false,
        code: 'invalid_agent',
        reason: 'request body is not JSON',
      },
      { status: 400 },
    );
  }

  const result = await setTerminalAgent(body.agent);
  if (!result.ok) return Response.json(result, { status: 400 });
  return Response.json(result);
}
