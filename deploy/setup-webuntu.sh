#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-webuntu.sh — deploy Webuntu (+ optional networking relay) on a fresh Ubuntu VPS.
#
# The Node server (server.mjs) serves the app with the mandatory COOP/COEP isolation
# headers (-> SharedArrayBuffer, required by qemu-wasm threads), HTTP Range, and caching.
# Caddy (installed automatically when you pass a DOMAIN) terminates TLS. The relay
# (c2w-net, leashed) gives instances real internet when a user toggles networking on.
#
# Run ON THE BOX:
#   DOMAIN=box.eths.dev bash setup-webuntu.sh                          # app only, auto-HTTPS
#   DOMAIN=box.eths.dev RELAY_DOMAIN=relay.eths.dev bash setup-webuntu.sh   # app + relay (full)
#   bash setup-webuntu.sh                                              # local test, no TLS
#
# For each *_DOMAIN: point its DNS A/AAAA record at this box FIRST, and open ports 80+443.
# Relay leash (keep under your egress cap): BUDGET_TB (default 8), RATE_MBPS (default 25).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_URL="https://github.com/ethandacat/ethan-codes.com.git"
REL="https://github.com/ethandacat/ethan-codes.com/releases/latest/download"
APP_DIR="${APP_DIR:-/opt/webuntu}"
PORT="${PORT:-8099}"
DOMAIN="${DOMAIN:-}"
RELAY_DOMAIN="${RELAY_DOMAIN:-}"
SNAP="public/vm-fb/jammy-min.snap.qcow2.gz"

echo "[*] base packages..."
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates

ensure_caddy() {
  command -v caddy >/dev/null && return 0
  echo "[*] installing Caddy..."
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y caddy
}

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
[ -f "$SNAP" ] || { echo "[*] downloading pre-booted snapshot (~345 MB)..."; curl -fL --retry 3 -o "$SNAP" "$REL/jammy-min.snap.qcow2.gz"; }
echo "[*] snapshot: $(ls -lh "$SNAP" | awk '{print $5}')"

# --- app systemd service ---
echo "[*] app service 'webuntu' on :$PORT ..."
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

# --- optional networking relay (c2w-net, leashed by net-relay.sh) ---
if [ -n "$RELAY_DOMAIN" ]; then
  echo "[*] setting up networking relay for $RELAY_DOMAIN ..."
  sudo apt-get install -y nftables
  ARCH="$(dpkg --print-architecture)"
  if [ ! -x /usr/local/bin/c2w-net ]; then
    case "$ARCH" in
      amd64|arm64)
        echo "[*] downloading c2w-net ($ARCH)..."
        sudo curl -fL --retry 3 -o /usr/local/bin/c2w-net "$REL/c2w-net.$ARCH"
        sudo chmod +x /usr/local/bin/c2w-net ;;
      *)
        echo "!! no prebuilt c2w-net for arch '$ARCH' — build from ktock/container2wasm and drop it at /usr/local/bin/c2w-net, then re-run." ;;
    esac
  fi
  if [ -x /usr/local/bin/c2w-net ]; then
    sudo chmod +x "$APP_DIR/deploy/net-relay.sh"
    sudo tee /etc/systemd/system/net-relay.service >/dev/null <<EOF
[Unit]
Description=Webuntu network relay (leashed c2w-net)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
ExecStart=$APP_DIR/deploy/net-relay.sh
Environment=LISTEN=127.0.0.1:8888
Environment=BUDGET_TB=${BUDGET_TB:-8}
Environment=RATE_MBPS=${RATE_MBPS:-25}
Environment=C2W_NET=/usr/local/bin/c2w-net
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now net-relay
    echo "[*] relay up on 127.0.0.1:8888 (budget ${BUDGET_TB:-8}TB/mo, allow 80/443/53, cap ${RATE_MBPS:-25}MB/s)."
  fi
fi

# --- TLS via Caddy: one Caddyfile built from whatever domains are set ---
if [ -n "$DOMAIN" ] || [ -n "$RELAY_DOMAIN" ]; then
  ensure_caddy
  : | sudo tee /etc/caddy/Caddyfile >/dev/null
  # COOP/COEP + Range + caching come from the Node app; Caddy just terminates TLS.
  # Caddy v2 upgrades WebSockets automatically, so the relay site needs no extra config.
  [ -n "$DOMAIN" ]       && printf '%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' "$DOMAIN" "$PORT"  | sudo tee -a /etc/caddy/Caddyfile >/dev/null
  [ -n "$RELAY_DOMAIN" ] && printf '%s {\n\treverse_proxy 127.0.0.1:8888\n}\n' "$RELAY_DOMAIN"  | sudo tee -a /etc/caddy/Caddyfile >/dev/null
  sudo systemctl restart caddy
fi

# --- summary ---
echo
echo "============================================================"
if [ -n "$DOMAIN" ]; then echo "  App:    https://$DOMAIN"; else echo "  App:    http://127.0.0.1:$PORT   (no TLS — pass DOMAIN= to add it)"; fi
[ -n "$RELAY_DOMAIN" ] && echo "  Relay:  wss://$RELAY_DOMAIN   (used when a user toggles networking on)"
echo "============================================================"
echo "  Point each *_DOMAIN's DNS at this box + open 80/443 (Caddy needs them for the cert)."
echo "  Update later:  bash setup-webuntu.sh        Relay internals: deploy/RELAY-DEPLOY.md"
