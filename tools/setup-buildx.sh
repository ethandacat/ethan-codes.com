#!/usr/bin/env bash
set -euo pipefail

echo "== install buildx CLI plugin =="
BX_VER=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
echo "buildx version: $BX_VER"
mkdir -p /root/.docker/cli-plugins
curl -sSL -o /root/.docker/cli-plugins/docker-buildx \
  "https://github.com/docker/buildx/releases/download/${BX_VER}/buildx-${BX_VER}.linux-amd64"
chmod +x /root/.docker/cli-plugins/docker-buildx
echo "-- buildx version --"
docker buildx version

echo "== create + bootstrap docker-container builder (pulls moby/buildkit) =="
docker buildx create --name c2wbuilder --driver docker-container --use 2>/dev/null || docker buildx use c2wbuilder
docker buildx inspect --bootstrap | sed -n '1,8p'
echo "BUILDX_READY"
