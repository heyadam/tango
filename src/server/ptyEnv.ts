import fs from 'node:fs';
import path from 'node:path';
import { terminalAgentMcpUrl } from './terminalAgent';

export function tangoCodexBinDir(workspace: string): string {
  return path.join(workspace, '.tango', 'bin');
}

function isExecutableFile(p: string): boolean {
  try {
    const stat = fs.statSync(p);
    if (!stat.isFile()) return false;
    if (process.platform === 'win32') return true;
    return (stat.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

export function findExecutableOnPath(
  executable: string,
  envPath: string | undefined,
  skipDirs: string[] = [],
): string | null {
  if (!envPath) return null;
  const skipped = new Set(skipDirs);
  const suffixes =
    process.platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : [''];

  for (const dir of envPath.split(path.delimiter)) {
    if (!dir || skipped.has(dir)) continue;
    for (const suffix of suffixes) {
      const candidate = path.join(dir, `${executable}${suffix}`);
      if (isExecutableFile(candidate)) return candidate;
    }
  }
  return null;
}

export function buildTerminalPtyEnv(
  workspace: string,
  port: number,
  baseEnv: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const codexBinDir = tangoCodexBinDir(workspace);
  const basePath = baseEnv.PATH ?? '';
  const realCodex =
    findExecutableOnPath('codex', basePath, [codexBinDir]) ??
    baseEnv.TANGO_CODEX_REAL_BIN;

  return {
    ...baseEnv,
    PATH: basePath
      ? `${codexBinDir}${path.delimiter}${basePath}`
      : codexBinDir,
    TERM: 'xterm-256color',
    COLORTERM: 'truecolor',
    TANGO_MCP_URL: terminalAgentMcpUrl(port),
    ...(realCodex ? { TANGO_CODEX_REAL_BIN: realCodex } : {}),
  };
}
