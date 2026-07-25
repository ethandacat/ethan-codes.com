#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# uninstall-litehost.sh — fully remove Litehost and free ports 80/443 so the
# Webuntu installer (which uses Caddy for auto-HTTPS) can take over the box.
#
# Reverses exactly what Litehost's install.sh creates. KEEPS Node.js (Webuntu
# uses it) and harmless base tools (git/curl/sqlite3/openssl/...). Purges only
# Litehost's own stack: nginx + php8.1.
#
# Run:  sudo bash uninstall-litehost.sh
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: keep going even if a piece is already gone

echo "[*] stopping Litehost + its web stack..."
sudo systemctl disable --now litehost   2>/dev/null || true
sudo systemctl disable --now nginx      2>/dev/null || true
sudo systemctl disable --now php8.1-fpm 2>/dev/null || true

echo "[*] removing systemd unit + CLI binary..."
sudo rm -f /etc/systemd/system/litehost.service /usr/local/bin/litehost
sudo systemctl daemon-reload

echo "[*] removing Litehost files, data + hosted sites..."
sudo rm -rf /opt/litehost /opt/hosted-sites /etc/hostctl /var/log/hostctl /tmp/litehost-uploads

echo "[*] removing nginx confs + sudoers/logrotate drop-ins..."
sudo rm -f /etc/nginx/conf.d/litehost.conf \
           /etc/nginx/sites-enabled/litehost-panel.conf \
           /etc/nginx/sites-available/litehost-panel.conf \
           /etc/sudoers.d/litehost /etc/logrotate.d/litehost

echo "[*] removing the 'litehost' system user..."
id litehost >/dev/null 2>&1 && sudo userdel litehost 2>/dev/null || true

echo "[*] purging nginx + php8.1 (Litehost-only; keeping Node.js, sqlite, base tools)..."
PHP_PKGS="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^php8\.1/ {print $2}')"
sudo apt-get purge -y nginx nginx-common nginx-core $PHP_PKGS 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Litehost enabled ufw; make sure Caddy's ports stay open (never touches SSH negatively).
if command -v ufw >/dev/null; then
  sudo ufw allow 80/tcp  2>/dev/null || true
  sudo ufw allow 443/tcp 2>/dev/null || true
fi

echo
echo "=== ports 80/443 should be free now ==="
sudo ss -ltnp 2>/dev/null | grep -E ':80 |:443 ' || echo "(nothing listening on 80/443 — ready for Caddy)"
echo "[*] Litehost removed. Run the Webuntu installer next."
