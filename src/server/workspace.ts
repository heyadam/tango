import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// The directory Claude operates in: where the in-app terminal lands, where
// `.mcp.json` lives so the `claude` CLI auto-discovers our canvas tools, and
// where `design-scratch/` PNGs land for the "Send to Claude" flow.
//
// Kept distinct from the tango repo on purpose — this lets you develop tango
// locally without your dev shell stepping on Claude's working tree.
//
// Override with TANGO_WORKSPACE=/some/path.

export const WORKSPACE_DIR = process.env.TANGO_WORKSPACE
  ? path.resolve(process.env.TANGO_WORKSPACE)
  : path.join(os.homedir(), 'dev', 'tangotest');

const MCP_CONFIG_PATH = path.join(WORKSPACE_DIR, '.mcp.json');
const CLAUDE_SETTINGS_PATH = path.join(WORKSPACE_DIR, '.claude', 'settings.json');

// Settings we always want present in the workspace's Claude Code config.
// Merged into whatever's already in settings.json — we don't clobber unrelated
// keys or hooks the user has set.
const REQUIRED_CLAUDE_ENV = {
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
} as const;

// Always overwrite — the tango app owns this file and it has to point at the
// running server. If the user has hand-edited it we'd rather they keep their
// edit somewhere else; this is generated config.
function mcpConfig(port: number): string {
  return JSON.stringify(
    {
      mcpServers: {
        'tango-canvas': {
          type: 'http',
          url: `http://localhost:${port}/mcp`,
        },
      },
    },
    null,
    2,
  ) + '\n';
}

async function readJsonOrEmpty(p: string): Promise<Record<string, unknown>> {
  try {
    const raw = await fs.readFile(p, 'utf8');
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

async function writeIfChanged(p: string, next: string): Promise<void> {
  let prev: string | null = null;
  try {
    prev = await fs.readFile(p, 'utf8');
  } catch {
    // missing — fall through to write
  }
  if (prev !== next) {
    await fs.writeFile(p, next);
  }
}

async function ensureClaudeSettings(): Promise<void> {
  const dir = path.dirname(CLAUDE_SETTINGS_PATH);
  await fs.mkdir(dir, { recursive: true });
  const current = await readJsonOrEmpty(CLAUDE_SETTINGS_PATH);
  const env = (current.env && typeof current.env === 'object' && !Array.isArray(current.env)
    ? (current.env as Record<string, unknown>)
    : {}) as Record<string, unknown>;
  const merged = { ...current, env: { ...env, ...REQUIRED_CLAUDE_ENV } };
  await writeIfChanged(CLAUDE_SETTINGS_PATH, JSON.stringify(merged, null, 2) + '\n');
}

export async function ensureWorkspace(port: number): Promise<void> {
  await fs.mkdir(WORKSPACE_DIR, { recursive: true });
  await fs.mkdir(path.join(WORKSPACE_DIR, 'design-scratch'), { recursive: true });
  await writeIfChanged(MCP_CONFIG_PATH, mcpConfig(port));
  await ensureClaudeSettings();
}
