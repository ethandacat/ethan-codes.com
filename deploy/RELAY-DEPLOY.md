# Webuntu relay — deploy & hardening checklist

The relay is what gives an in-browser instance real internet. It's the one piece
that runs on **your** server and can cost you money or be abused, so it ships
**off by default** and leashed. This is the runbook to stand it up safely.

Files in this folder:
- `net-relay.sh` — runs `c2w-net` as an unprivileged user, leashed by nftables
  (port allowlist 80/443/53, monthly egress budget, coarse rate cap).
- `net-relay.service` — systemd unit for the above.
- `Caddyfile` — TLS front so browsers can reach it over `wss://`.

---

## 0. Prerequisites (on the relay box — e.g. your Oracle always-free VM)
- Ubuntu/Debian, root access.
- `nftables` and `util-linux` (`setpriv`) installed: `apt-get install -y nftables`.
- The `c2w-net` binary built and at `/usr/local/bin/c2w-net`
  (from container2wasm; the Go 1.25 build we used).
- A DNS name for the relay, e.g. `relay.example.com`, pointed at this box.

## 1. Install the relay
```sh
sudo mkdir -p /opt/webuntu
sudo cp net-relay.sh RELAY-DEPLOY.md /opt/webuntu/
sudo chmod +x /opt/webuntu/net-relay.sh
sudo cp net-relay.service /etc/systemd/system/
```

Edit the budget/rate in `/etc/systemd/system/net-relay.service` to sit **under**
your provider's monthly egress cap (you have ~10 TB/mo → `BUDGET_TB=8` leaves headroom):
```
Environment=BUDGET_TB=8
Environment=RATE_MBPS=25
```

Start it:
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now net-relay
systemctl status net-relay          # should be active (running)
sudo ss -ltnp | grep 8888           # c2w-net listening on 127.0.0.1:8888
sudo nft list table inet netrelay   # allowlist + counters installed
```

## 2. TLS front (so HTTPS pages can reach it over wss)
A browser page served over HTTPS **cannot** open `ws://` — it must be `wss://`.
Caddy handles the cert automatically.
```sh
sudo apt-get install -y caddy
sudo cp Caddyfile /etc/caddy/Caddyfile
# edit relay.example.com -> your real hostname
sudo systemctl restart caddy
# from your laptop:
#   wss handshake test — expect HTTP/1.1 101 Switching Protocols
curl -si -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Key: x" -H "Sec-WebSocket-Version: 13" \
     https://relay.example.com/ | head -1
```

## 3. Point the app at your relay
The client reads `window.__RELAY` (host:port) and, for TLS, the WebSocket scheme.
Serve a tiny config that loads before `uvm-arg.js`, e.g. add to `public/vm-fb/uvm.html`
`<head>` (before the module script):
```html
<script>
  // production relay
  window.__RELAY = 'relay.example.com:443';
  // Emscripten SOCKFS builds ws:// by default; force wss:// for HTTPS pages.
  window.Module = window.Module || {};
  window.Module.websocket = { url: 'wss://' };
</script>
```
Leave these unset for local dev (defaults to `localhost:8888` over `ws://`).

## 4. End-to-end verification (do all of these before launch)
From a Webuntu instance with **networking toggled on**:
1. **It works:** `curl -sSI https://example.com | head -1` → `HTTP/2 200`.
2. **Allowlist holds:** `curl -m5 http://example.com:25` (SMTP) and an ssh attempt
   to port 22 should **fail/refuse** — only 80/443/53 are allowed.
3. **Counters move:** on the box, `sudo nft list counter inet netrelay egress`
   should climb as traffic flows.
4. **Budget trips:** temporarily set `BUDGET_TB` to a tiny value, restart, push some
   traffic, and confirm the service pauses networking (log: "monthly budget reached").
   Reset it afterward.
5. **Rate cap:** a big download should be throttled near `RATE_MBPS`, not unbounded.

## 5. Ongoing
- **Watch spend:** `cat /var/lib/net-relay/$(date -u +%Y-%m).bytes` — persisted
  month-to-date egress; alert when it nears the budget.
- **Logs:** `journalctl -u net-relay -f`.
- **Abuse:** the allowlist blocks the obvious open-proxy uses (mail, game servers,
  SSH tunnels). For extra safety, add per-source connection limits at Caddy/nginx
  and rotate the relay hostname if it gets scanned.
- **Kill switch:** `sudo systemctl stop net-relay` removes the nftables table and
  drops all instance networking immediately; the app degrades to fully-local.

## Notes
- TLS to real sites stays **end-to-end**: the relay is a raw TCP tunnel, so it sees
  ciphertext, not your data. It can see *which hosts/ports* you reach (like any ISP),
  not the contents.
- With the relay **down or absent**, instances still run — they're just offline.
  That's the default state, so a relay outage never breaks Webuntu, only its network.
