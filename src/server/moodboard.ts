// Server-side helpers shared by the moodboard generation routes.
//
// `saveMoodboardPng` writes a base64-encoded PNG into
// `<workspace>/design-scratch/moodboard/` and returns the workspace-relative
// path (so the terminal agent, MCP tools, and tango-memory.md all reference
// the same string).
//
// `encodeStripePng` is a no-deps PNG encoder used by the seed route to make
// dummy moodboard images out of a palette without calling OpenAI. RGB only,
// filter type 0, single IDAT — enough for a colored landscape stripe and
// nothing more.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { deflateSync } from 'node:zlib';

export const MOODBOARD_SUBDIR = 'design-scratch/moodboard';

export async function saveMoodboardPng(
  workspace: string,
  base64: string,
): Promise<string> {
  const dir = path.join(workspace, MOODBOARD_SUBDIR);
  await fs.mkdir(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const suffix = randomBytes(2).toString('hex');
  const filename = `${stamp}-${suffix}.png`;
  await fs.writeFile(path.join(dir, filename), Buffer.from(base64, 'base64'));
  return `${MOODBOARD_SUBDIR}/${filename}`;
}

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function parseHex(hex: string): [number, number, number] {
  const m = hex.trim().match(/^#?([0-9a-f]{6})$/i);
  if (!m) throw new Error(`Invalid hex color: ${hex}`);
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

// Vertical bands of equal width, one per color, painted across an RGB raster.
// Used by the seed route — anything fancier (gradients, text) belongs upstream
// in the real generation flow.
export function encodeStripePng(
  width: number,
  height: number,
  hexes: string[],
): Buffer {
  if (hexes.length === 0) throw new Error('encodeStripePng requires at least one color');
  const colors = hexes.map(parseHex);
  const stride = width * 3;
  const raster = new Uint8Array(stride * height);
  const row = new Uint8Array(stride);
  for (let x = 0; x < width; x += 1) {
    const idx = Math.min(
      colors.length - 1,
      Math.floor((x / width) * colors.length),
    );
    const [r, g, b] = colors[idx];
    row[x * 3] = r;
    row[x * 3 + 1] = g;
    row[x * 3 + 2] = b;
  }
  for (let y = 0; y < height; y += 1) {
    raster.set(row, y * stride);
  }

  // Add a filter byte (0 = None) at the start of each scanline.
  const filtered = Buffer.alloc(height * (stride + 1));
  for (let y = 0; y < height; y += 1) {
    filtered[y * (stride + 1)] = 0;
    Buffer.from(raster.buffer, raster.byteOffset + y * stride, stride).copy(
      filtered,
      y * (stride + 1) + 1,
    );
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type RGB
  ihdr[10] = 0; // compression: deflate
  ihdr[11] = 0; // filter: adaptive
  ihdr[12] = 0; // interlace: none

  const idat = deflateSync(filtered);
  return Buffer.concat([
    PNG_SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
