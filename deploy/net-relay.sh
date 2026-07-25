#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# net-relay.sh — bounded network relay for the browser VM.
#
# Runs c2w-net (the gvisor TCP/IP proxy) as an UNPRIVILEGED user, leashed so it
# can't cost you money or be abused as an open proxy:
#
#   1. PORT ALLOWLIST — the relay user may only reach 80 (HTTP), 443 (HTTPS),
#      53 (DNS). apt/pip/curl/git-over-https work; torrents, game servers, spam
#      relays, SSH tunnels, etc. do not.
#   2. MONTHLY EGRESS BUDGET — an nftables byte counter is watched; when this
#      month's egress reaches the budget the relay is stopped (networking simply
#      goes offline) until the 1st of next month. Set the budget UNDER your
#      provider's free-tier egress cap so you can never hit an overage charge.
#   3. RATE CAP — a coarse per-second byte limit so one session can't firehose.
#
# Run as root on your relay host (e.g. an Oracle Cloud always-free VM):
#   sudo BUDGET_TB=8 LISTEN=0.0.0.0:8888 ./net-relay.sh
# Then reverse-proxy wss://your-domain/ -> that port (TLS terminates at your proxy).
# ---------------------------------------------------------------------------
set -euo pipefail

RELAY_USER="${RELAY_USER:-netrelay}"
C2W_NET="${C2W_NET:-/usr/local/bin/c2w-net}"
LISTEN="${LISTEN:-127.0.0.1:8888}"          # ws listen addr (front with a TLS reverse proxy)
BUDGET_TB="${BUDGET_TB:-8}"                  # monthly egress budget in TB (< your free-tier cap)
RATE_MBPS="${RATE_MBPS:-25}"                 # coarse per-second cap, megabytes/second
POLL_SECS="${POLL_SECS:-30}"                 # how often to check the budget
STATE_DIR="${STATE_DIR:-/var/lib/net-relay}"
TABLE="netrelay"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need nft; need setpriv; [ -x "$C2W_NET" ] || { echo "c2w-net not at $C2W_NET" >&2; exit 1; }

# --- unprivileged user whose egress we police -------------------------------
id "$RELAY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$RELAY_USER"
RUID="$(id -u "$RELAY_USER")"
mkdir -p "$STATE_DIR"

BUDGET_BYTES=$(( BUDGET_TB * 1000 * 1000 * 1000 * 1000 ))
RATE_BYTES=$(( RATE_MBPS * 1000 * 1000 ))

install_rules() {
  nft delete table inet "$TABLE" 2>/dev/null || true
  nft -f - <<EOF
table inet $TABLE {
  counter egress { }
  chain output {
    type filter hook output priority 0; policy accept;
    # only police traffic originating from the relay user
    meta skuid != $RUID accept
    oif "lo" accept
    # coarse anti-firehose throughput cap (drop the excess)
    limit rate over ${RATE_BYTES} bytes/second burst $(( RATE_BYTES * 2 )) bytes drop
    # ALLOWLIST: HTTP / HTTPS / DNS  -> count the bytes (for the budget) and allow
    tcp dport { 80, 443 } counter name egress accept
    tcp dport 53 counter name egress accept
    udp dport 53 counter name egress accept
    # everything else from the relay user is refused
    counter reject
  }
}
EOF
}

egress_bytes() { nft -j list counter inet "$TABLE" egress 2>/dev/null \
  | grep -o '"bytes":[0-9]*' | head -1 | cut -d: -f2 || echo 0; }

reset_counter() { nft reset counter inet "$TABLE" egress >/dev/null 2>&1 || true; }

start_relay() {
  [ -n "${RELAY_PID:-}" ] && kill -0 "$RELAY_PID" 2>/dev/null && return
  echo "[net-relay] starting c2w-net as $RELAY_USER on $LISTEN"
  setpriv --reuid "$RELAY_USER" --regid "$RELAY_USER" --clear-groups \
    "$C2W_NET" -listen-ws "$LISTEN" &
  RELAY_PID=$!
}
stop_relay() {
  [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null || true
  RELAY_PID=""
}

trap 'stop_relay; nft delete table inet "$TABLE" 2>/dev/null || true; exit 0' INT TERM

install_rules
MONTH="$(date -u +%Y-%m)"
# carry over accumulated bytes across restarts within the same month
ACC=0; [ -f "$STATE_DIR/$MONTH.bytes" ] && ACC="$(cat "$STATE_DIR/$MONTH.bytes")"
reset_counter
start_relay

echo "[net-relay] budget ${BUDGET_TB} TB/mo, allow 80/443/53, cap ${RATE_MBPS} MB/s"
while true; do
  sleep "$POLL_SECS"
  now="$(date -u +%Y-%m)"
  if [ "$now" != "$MONTH" ]; then           # month rollover -> fresh budget
    MONTH="$now"; ACC=0; reset_counter; : > "$STATE_DIR/$MONTH.bytes"
    start_relay
  fi
  used=$(( ACC + $(egress_bytes) ))
  echo "$used" > "$STATE_DIR/$MONTH.bytes"
  if [ "$used" -ge "$BUDGET_BYTES" ]; then
    if [ -n "${RELAY_PID:-}" ]; then
      echo "[net-relay] monthly budget reached ($used bytes) — pausing networking until next month"
      stop_relay
    fi
  else
    start_relay
  fi
done
