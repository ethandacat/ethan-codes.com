#!/usr/bin/env bash
set -euo pipefail

echo "== [1/4] docker pull ubuntu:22.04 =="
docker pull ubuntu:22.04

# NOTE: output to /root (ext4, persistent) NOT /tmp — systemd makes /tmp a tmpfs
# that is wiped when the WSL distro restarts.
OUT=/root/vm-out
rm -rf "$OUT"; mkdir -p "$OUT"

echo "== [2/4] c2w --to-js ubuntu:22.04  (cache should make this fast now) =="
# c2w v0.8.4 embeds the OLD source repo (ktock/container2wasm), which lacks the
# v0.8.4 tag since the project moved to the container2wasm org. Point it right.
date +"start: %H:%M:%S"
c2w --to-js \
  --build-arg SOURCE_REPO=https://github.com/container2wasm/container2wasm \
  ubuntu:22.04 "$OUT/"
date +"end:   %H:%M:%S"

echo "== [3/4] built artifacts =="
ls -la "$OUT"
du -sh "$OUT"

echo "== [4/4] copy into the project's public/vm =="
DEST=/mnt/c/Users/ethan/Work/ethan-codes.com/public/vm
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$OUT"/. "$DEST"/
echo "copied to $DEST:"
ls -la "$DEST"
echo "BUILD_DONE"
