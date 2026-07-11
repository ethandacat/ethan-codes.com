// Static host for the in-browser Ubuntu VM.
//
// Two hard requirements the emulator bundle depends on:
//   1. Cross-origin isolation (COOP + COEP) so the page gets SharedArrayBuffer,
//      which qemu-wasm/Emscripten pthreads (MTTCG) require.
//   2. HTTP Range support + correct MIME types, so large .wasm and the
//      lazily-streamed disk image can be fetched in byte ranges.
//
// Usage: node server.mjs  (serves ./public on http://localhost:8080)

import { createServer } from 'node:http';
import { stat, open } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), 'public');
const PORT = Number(process.env.PORT ?? 8080);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.map': 'application/json; charset=utf-8',
  '.img': 'application/octet-stream',
  '.bin': 'application/octet-stream',
  '.svg': 'image/svg+xml',
};

function isoHeaders(res) {
  // The two headers that unlock SharedArrayBuffer.
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
}

const server = createServer(async (req, res) => {
  try {
    isoHeaders(res);

    // Resolve path, block traversal, default to index.html.
    let rel = decodeURIComponent((req.url ?? '/').split('?')[0]);
    if (rel.endsWith('/')) rel += 'index.html';
    const path = normalize(join(ROOT, rel));
    if (!path.startsWith(ROOT)) { res.writeHead(403).end('Forbidden'); return; }

    const info = await stat(path).catch(() => null);
    if (!info || !info.isFile()) { res.writeHead(404).end('Not found'); return; }

    const type = MIME[extname(path).toLowerCase()] ?? 'application/octet-stream';
    res.setHeader('Content-Type', type);
    res.setHeader('Accept-Ranges', 'bytes');

    // Range request (essential for streaming the disk image + big wasm).
    const range = req.headers.range;
    if (range) {
      const m = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (m) {
        let start = m[1] ? Number(m[1]) : 0;
        let end = m[2] ? Number(m[2]) : info.size - 1;
        if (Number.isNaN(start) || Number.isNaN(end) || start > end || end >= info.size) {
          res.writeHead(416, { 'Content-Range': `bytes */${info.size}` }).end();
          return;
        }
        const fh = await open(path);
        res.writeHead(206, {
          'Content-Range': `bytes ${start}-${end}/${info.size}`,
          'Content-Length': end - start + 1,
        });
        fh.createReadStream({ start, end }).pipe(res).on('close', () => fh.close());
        return;
      }
    }

    const fh = await open(path);
    res.writeHead(200, { 'Content-Length': info.size });
    fh.createReadStream().pipe(res).on('close', () => fh.close());
  } catch (err) {
    res.writeHead(500).end(String(err));
  }
});

server.listen(PORT, () => {
  console.log(`browser-ubuntu host → http://localhost:${PORT}  (COOP/COEP + range enabled)`);
});
