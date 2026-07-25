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
  // The headers that unlock SharedArrayBuffer. 'credentialless' still yields
  // cross-origin isolation but lets no-CORS cross-origin subresources (the
  // xterm/xterm-pty CDN scripts) load without CORP headers. Vendor + switch
  // to 'require-corp' for production.
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'credentialless');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
}

const server = createServer(async (req, res) => {
  try {
    isoHeaders(res);

    // Resolve path, block traversal, default to index.html.
    let rel = decodeURIComponent((req.url ?? '/').split('?')[0]);
    if (rel.endsWith('/')) rel += 'index.html';
    let path = normalize(join(ROOT, rel));
    if (!path.startsWith(ROOT)) { res.writeHead(403).end('Forbidden'); return; }

    // Directory request (e.g. /instances) -> serve its index.html.
    const dinfo = await stat(path).catch(() => null);
    if (dinfo && dinfo.isDirectory()) path = join(path, 'index.html');

    const type = MIME[extname(path).toLowerCase()] ?? 'application/octet-stream';

    const info = await stat(path).catch(() => null);
    const gz = await stat(path + '.gz').catch(() => null);   // pre-compressed sibling, if any
    const acceptsGzip = /\bgzip\b/.test(req.headers['accept-encoding'] || '');

    // Validate against the raw file when present, else the .gz (snapshot case).
    const vstat = info && info.isFile() ? info : (gz && gz.isFile() ? gz : null);
    if (!vstat) { res.writeHead(404).end('Not found'); return; }

    // Revalidating cache: browsers keep the (345 MB) snapshot etc. and re-check with a
    // conditional GET. Unchanged -> a tiny 304, no re-download. A re-snapshot changes the
    // file's size/mtime -> new ETag -> the browser fetches the new bytes once. Safe by
    // default (no stale-forever 'immutable' footgun).
    const etag = `"${vstat.size.toString(16)}-${Math.round(vstat.mtimeMs).toString(16)}"`;
    res.setHeader('ETag', etag);
    res.setHeader('Last-Modified', new Date(vstat.mtimeMs).toUTCString());
    res.setHeader('Cache-Control', 'public, max-age=0, must-revalidate');
    if (req.headers['if-none-match'] === etag) { res.writeHead(304).end(); return; }

    res.setHeader('Content-Type', type);

    if (!(info && info.isFile())) {
      // Raw file absent but a .gz exists (e.g. the big snapshot disk) -> serve it encoded.
      if (acceptsGzip && gz && gz.isFile()) {
        const gfh = await open(path + '.gz');
        res.writeHead(200, {
          'Content-Length': gz.size,
          'Content-Encoding': 'gzip',
          'Vary': 'Accept-Encoding',
        });
        gfh.createReadStream().pipe(res).on('close', () => gfh.close());
        return;
      }
      res.writeHead(404).end('Not found'); return;
    }

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

    // Transparent pre-compressed sibling: if <path>.gz exists and the client
    // accepts gzip, serve that with Content-Encoding: gzip. The browser
    // decompresses for us, so the big snapshot qcow2 downloads ~35% smaller with
    // zero client changes. (Only for full GETs — gzip doesn't compose with Range.)
    if (acceptsGzip) {
      if (gz && gz.isFile()) {
        const gfh = await open(path + '.gz');
        res.removeHeader('Accept-Ranges');
        res.writeHead(200, {
          'Content-Length': gz.size,
          'Content-Encoding': 'gzip',
          'Vary': 'Accept-Encoding',
        });
        gfh.createReadStream().pipe(res).on('close', () => gfh.close());
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
