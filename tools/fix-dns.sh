#!/usr/bin/env bash
set -euo pipefail

echo "== set docker daemon DNS to public resolvers =="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{ "dns": ["8.8.8.8", "1.1.1.1"] }
JSON
systemctl restart docker
sleep 3
docker version --format 'server {{.Server.Version}}'

echo "== DNS smoke test inside a container =="
docker run --rm busybox nslookup registry-1.docker.io 2>&1 | sed -n '1,10p' || true

echo "== recreate buildx builder with host networking =="
docker buildx rm c2wbuilder 2>/dev/null || true
docker buildx create --name c2wbuilder --driver docker-container --driver-opt network=host --use
docker buildx inspect --bootstrap | sed -n '1,8p'
echo "FIX_DONE"
