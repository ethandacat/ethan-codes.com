#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-webuntu.sh — deploy Webuntu on any fresh Ubuntu VPS. No control panel needed.
#
# Installs Node + the app + (optionally) Caddy for automatic HTTPS, and runs it as a
# systemd service. The bundled Node server (server.mjs) sets the mandatory
# Cross-Origin-Isolation headers (COOP/COEP -> SharedArrayBuffer, which qemu-wasm's
# threads REQUIRE), plus HTTP Range and ETag caching — so no host/proxy header config
# is needed.
#
# Run ON THE BOX:
#   DOMAIN=box.eths.dev bash setup-webuntu.sh    # full: app + auto-HTTPS on your domain
#   bash setup-webuntu.sh                         # app only on :8099 (bring your own TLS)
#
# For DOMAIN mode: point the domain's DNS A/AAAA record at this box FIRST, and open
# ports 80 + 443 (Caddy needs them to get the Let's Encrypt cert).
#
# The networking relay (real internet for the "on" toggle) is separate + optional:
# see deploy/RELAY-DEPLOY.md.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_URL="https://github.com/ethandacat/ethan-codes.com.git"
SNAP_URL="https://github.com/ethandacat/ethan-codes.com/releases/latest/download/jammy-min.snap.qcow2.gz"
APP_DIR="${APP_DIR:-/opt/webuntu}"
PORT="${PORT:-8099}"
DOMAIN="${DOMAIN:-}"
SNAP="public/vm-fb/jammy-min.snap.qcow2.gz"

echo "[*] base packages..."
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates

# --- Node.js 20+ ---
NODEMAJ="$(node -v 2>/dev/null | sed -n 's/^v\([0-9]\+\).*/\1/p' || true)"
if [ -z "$NODEMAJ" ] || [ "$NODEMAJ" -lt 18 ]; then
  echo "[*] installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# --- app code (public repo -> no auth) ---
if [ -d "$APP_DIR/.git" ]; then
  echo "[*] updating $APP_DIR ..."; git -C "$APP_DIR" pull --ff-only
else
  echo "[*] cloning -> $APP_DIR ..."; sudo mkdir -p "$APP_DIR"; sudo chown "$(id -un)" "$APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

# --- 345 MB pre-booted snapshot (a Release asset, not in git) ---
if [ ! -f "$SNAP" ]; then
  echo "[*] downloading pre-booted snapshot (~345 MB)..."
  curl -fL --retry 3 -o "$SNAP" "$SNAP_URL"
fi
echo "[*] snapshot: $(ls -lh "$SNAP" | awk '{print $5}')"

# --- run server.mjs as a systemd service ---
echo "[*] installing systemd service 'webuntu' on port $PORT ..."
sudo tee /etc/systemd/system/webuntu.service >/dev/null <<EOF
[Unit]
Description=Webuntu app (browser Ubuntu VM host)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
Environment=PORT=$PORT
ExecStart=$(command -v node) server.mjs
Restart=on-failure
RestartSec=3
User=$(id -un)

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now webuntu
sleep 1
curl -sS -o /dev/null -w "[*] app check: HTTP %{http_code} on 127.0.0.1:$PORT\n" "http://127.0.0.1:$PORT/" || true

# --- HTTPS via Caddy (only if DOMAIN is set) ---
if [ -n "$DOMAIN" ]; then
  if ! command -v caddy >/dev/null; then
    echo "[*] installing Caddy..."
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y caddy
  fi
  echo "[*] configuring Caddy for https://$DOMAIN ..."
  sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
$DOMAIN {
	# COOP/COEP + Range + caching come from the Node app; Caddy just terminates TLS.
	reverse_proxy 127.0.0.1:$PORT
}
EOF
  sudo systemctl restart caddy
  echo
  echo "============================================================"
  echo "  Webuntu is LIVE:   https://$DOMAIN"
  echo "============================================================"
  echo "  (DNS for $DOMAIN must point at this box + 80/443 open for the cert.)"
else
  echo
  echo "============================================================"
  echo "  Webuntu app is running on 127.0.0.1:$PORT (no TLS yet)."
  echo "  Add HTTPS by re-running with your domain:"
  echo "      DOMAIN=box.eths.dev bash setup-webuntu.sh"
  echo "============================================================"
fi
echo "Update later:  bash setup-webuntu.sh   |   Networking relay: deploy/RELAY-DEPLOY.md"
