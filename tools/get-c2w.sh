#!/usr/bin/env bash
set -euo pipefail

echo "== fetching latest container2wasm release =="
API=https://api.github.com/repos/container2wasm/container2wasm/releases/latest
TAG=$(curl -s "$API" | grep -oP '"tag_name":\s*"\K[^"]+')
echo "latest tag: $TAG"

URL=$(curl -s "$API" | grep -oP '"browser_download_url":\s*"\K[^"]+' | grep -iE 'linux[-_]amd64' | head -1)
echo "asset: ${URL:-<none found>}"
if [ -z "${URL:-}" ]; then
  echo "!! no linux-amd64 asset; all assets:"
  curl -s "$API" | grep -oP '"browser_download_url":\s*"\K[^"]+'
  exit 1
fi

cd /tmp
rm -rf c2wdir c2w.tar.gz
curl -sSL -o c2w.tar.gz "$URL"
mkdir -p c2wdir && tar xzf c2w.tar.gz -C c2wdir
echo "== extracted =="
ls -R c2wdir

BIN=$(find c2wdir -type f -name c2w | head -1)
echo "c2w binary: ${BIN:-<not found>}"
[ -n "${BIN:-}" ] || { echo "!! c2w binary not in tarball"; exit 1; }
install -m 0755 "$BIN" /usr/local/bin/c2w

# stash the helper wasms next to a known dir too (c2w-net-proxy.wasm etc.)
find c2wdir -type f -name '*.wasm' -exec cp {} /usr/local/lib/ \; 2>/dev/null || true

echo "== c2w installed =="
which c2w
c2w --help 2>&1 | head -20 || true
