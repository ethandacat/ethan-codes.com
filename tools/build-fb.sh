#!/usr/bin/env bash
set -euo pipefail

SC=/mnt/c/Users/ethan/AppData/Local/Temp/claude/C--Users-ethan-Work-Tianrun-Energy-Storage/0579e3bf-d5c2-437b-b37d-5523246e1c02/scratchpad

echo "== [1/3] build lightweight desktop source image (ubuntu-desktop) =="
mkdir -p /tmp/dctx
docker buildx build --builder c2wbuilder --load -t ubuntu-desktop -f "$SC/Dockerfile.desktop" /tmp/dctx

OUT=/root/vm-fb-out
rm -rf "$OUT"; mkdir -p "$OUT"

echo "== [2/3] c2w --to-js with framebuffer-enabled kernel (bochs-drm + fbdev) =="
date +"start: %H:%M:%S"
c2w --to-js \
  --dockerfile "$SC/Dockerfile.fb" \
  --assets "$SC/c2w-src" \
  --build-arg SOURCE_REPO=https://github.com/container2wasm/container2wasm \
  --build-arg VM_MEMORY_SIZE_MB=2047 \
  ubuntu-desktop "$OUT/"
date +"end:   %H:%M:%S"

echo "== [3/3] output =="
ls -la "$OUT"; du -sh "$OUT"
echo "FB_BUILD_DONE"
