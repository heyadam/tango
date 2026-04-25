import { spawn } from 'node:child_process';
import os from 'node:os';

// Server-side native folder picker. Tango runs a custom Node server on the
// user's own machine, so we can shell out to the OS's native dialog and
// return the absolute path. Browsers won't give us an absolute path even
// with `webkitdirectory` (security restriction).
//
// macOS: AppleScript `choose folder`.
// Other platforms: not implemented yet — caller should fall back to the path
// input. Electron will swap this whole route for `dialog.showOpenDialog`.

type BrowseOk = { ok: true; path: string };
type BrowseErr =
  | { ok: false; code: 'cancelled' }
  | { ok: false; code: 'unsupported_platform'; platform: string }
  | { ok: false; code: 'error'; reason: string };

function runOsascript(script: string): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve, reject) => {
    const child = spawn('osascript', ['-e', script], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => {
      stdout += d.toString();
    });
    child.stderr.on('data', (d) => {
      stderr += d.toString();
    });
    child.on('error', reject);
    child.on('close', (code) => {
      resolve({ stdout, stderr, code: code ?? 0 });
    });
  });
}

export async function POST(): Promise<Response> {
  const platform = os.platform();
  if (platform !== 'darwin') {
    const body: BrowseErr = {
      ok: false,
      code: 'unsupported_platform',
      platform,
    };
    return Response.json(body, { status: 501 });
  }

  // `choose folder` returns an HFS path (e.g., "Macintosh HD:Users:adam:dev");
  // wrapping in `POSIX path of (…)` converts to an absolute POSIX path.
  //
  // We don't try to activate osascript itself — recent macOS rejects that
  // with `-10006` because osascript isn't a registered foreground app. The
  // dialog is modal and grabs focus on its own; on the rare case it ends up
  // behind the browser, the user can `Cmd+Tab` to it. (Bringing Finder to
  // front would shift focus *away* from the browser, which is worse.)
  const script = `
try
  set chosen to choose folder with prompt "Pick a project folder for tango"
  return POSIX path of chosen
on error errMsg number errNum
  if errNum is -128 then
    return "__CANCELLED__"
  else
    error errMsg number errNum
  end if
end try
`.trim();

  let result;
  try {
    result = await runOsascript(script);
  } catch (err) {
    const body: BrowseErr = {
      ok: false,
      code: 'error',
      reason: err instanceof Error ? err.message : String(err),
    };
    return Response.json(body, { status: 500 });
  }

  if (result.code !== 0) {
    const body: BrowseErr = {
      ok: false,
      code: 'error',
      reason: result.stderr.trim() || `osascript exited with code ${result.code}`,
    };
    return Response.json(body, { status: 500 });
  }

  const out = result.stdout.trim();
  if (out === '__CANCELLED__' || out === '') {
    const body: BrowseErr = { ok: false, code: 'cancelled' };
    return Response.json(body, { status: 200 });
  }

  // POSIX paths from `choose folder` end with a trailing slash; strip it so
  // the path matches what users typically type.
  const path = out.endsWith('/') && out !== '/' ? out.slice(0, -1) : out;

  const body: BrowseOk = { ok: true, path };
  return Response.json(body);
}
