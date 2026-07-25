#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-webuntu.sh — stand up the Webuntu app on an Ubuntu box (e.g. a Litehost VM).
#
# Serves the browser-VM app via the bundled Node server (server.mjs). server.mjs
# sets the mandatory Cross-Origin-Isolation headers (COOP/COEP -> SharedArrayBuffer,
# which qemu-wasm's threads REQUIRE), HTTP Range, and ETag caching itself — so you
# do NOT need the host panel to support custom headers. Front it with Litehost/Nginx
# for TLS on box.eths.dev.
#
# One-time prereqs on the box:
#   sudo apt-get update && sudo apt-get install -y gh git curl
#   gh auth login          # this repo is private, so gh must be authed
#
# Then:  bash setup-webuntu.sh
#
# The relay (real networking) is a SEPARATE, optional piece — see RELAY-DEPLOY.md.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="ethandacat/ethan-codes.com"
APP_DIR="${APP_DIR:-/opt/webuntu}"
PORT="${PORT:-8099}"
SNAPSHOT="public/vm-fb/jammy-min.snap.qcow2.gz"

# --- prereqs ---
miss=0; for c in git curl gh; do command -v "$c" >/dev/null || { echo "missing: $c"; miss=1; }; done
[ "$miss" = 1 ] && { echo "install the above first (gh: apt-get install -y gh && gh auth login), then re-run."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first (repo is private)."; exit 1; }

# --- Node.js 20+ ---
NODEMAJ="$(node -v 2>/dev/null | sed -n 's/^v\([0-9]\+\).*/\1/p' || true)"
if [ -z "$NODEMAJ" ] || [ "$NODEMAJ" -lt 18 ]; then
  echo "[*] installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# --- code (clone or update) ---
if [ -d "$APP_DIR/.git" ]; then
  echo "[*] updating $APP_DIR ..."
  git -C "$APP_DIR" pull --ff-only
else
  echo "[*] cloning $REPO -> $APP_DIR ..."
  sudo mkdir -p "$APP_DIR"; sudo chown "$(id -un)" "$APP_DIR"
  gh repo clone "$REPO" "$APP_DIR"
fi
cd "$APP_DIR"

# --- the 345 MB pre-booted snapshot (a Release asset, not in git) ---
if [ ! -f "$SNAPSHOT" ]; then
  echo "[*] downloading pre-booted snapshot from the latest Release..."
  gh release download -R "$REPO" --pattern 'jammy-min.snap.qcow2.gz' -D public/vm-fb/ --clobber
fi
echo -n "[*] snapshot: "; ls -lh "$SNAPSHOT" | awk '{print $5}'

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
curl -sS -o /dev/null -w "[*] local check: HTTP %{http_code}\n" "http://127.0.0.1:$PORT/" || true

cat <<NEXT

============================================================================
 Webuntu is live on 127.0.0.1:$PORT  (systemctl status webuntu)
============================================================================
Now point box.eths.dev at it. In Litehost, create a site for box.eths.dev and
proxy it to this port; the generated Nginx 'location' needs these two lines
(the rest of the isolation/Range headers come straight from the Node app —
don't strip them):

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_buffering off;            # stream the 345MB snapshot + 49MB wasm
        proxy_read_timeout 3600s;       # long-lived VM sessions
    }

Let Litehost/Let's Encrypt issue TLS for box.eths.dev, then open
https://box.eths.dev — it should boot Ubuntu.

To update later:  bash setup-webuntu.sh   (pulls + restarts)
Networking relay (optional): see deploy/RELAY-DEPLOY.md
NEXT
