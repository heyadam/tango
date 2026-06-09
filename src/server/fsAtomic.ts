import { promises as fs } from 'node:fs';
import { randomBytes } from 'node:crypto';

// Atomic-on-Darwin/Linux: same-fs rename is atomic, so a kill -9 mid-write
// leaves either the old file or the new file, never a half-written truncation.
export async function atomicWrite(dest: string, content: string): Promise<void> {
  const tmp = `${dest}.${randomBytes(4).toString('hex')}.tmp`;
  await fs.writeFile(tmp, content);
  try {
    await fs.rename(tmp, dest);
  } catch (err) {
    // Best-effort cleanup if rename failed.
    try {
      await fs.unlink(tmp);
    } catch {
      /* noop */
    }
    throw err;
  }
}
