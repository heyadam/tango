// Adapter for persisting a canvas snapshot. Web build POSTs to a route handler
// that writes into ./design-scratch/. The Electron build will swap this single
// file for a direct fs.writeFile against userData; same call site, no other
// changes.

export type WrittenSnapshot = {
  relPath: string;
  absPath: string;
};

export async function writeSnapshot(
  blob: Blob,
  options?: { caption?: string },
): Promise<WrittenSnapshot> {
  const url =
    options?.caption && options.caption.trim()
      ? `/api/design/snapshot?caption=${encodeURIComponent(options.caption.trim())}`
      : '/api/design/snapshot';
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'image/png' },
    body: blob,
  });
  if (!res.ok) {
    throw new Error(`writeSnapshot failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}
