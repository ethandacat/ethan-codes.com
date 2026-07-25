// QEMU args to RESTORE a pre-booted Ubuntu 22.04 snapshot instantly, with a
// user-toggleable network.
//
// Networking preference: ?net=off in the URL, else localStorage 'ubuntu_net',
// else default 'on'. The virtio-net DEVICE must ALWAYS be present because the
// snapshot was saved with it (-loadvm rejects a device mismatch). Only the
// netdev BACKEND target changes — it isn't part of the migration state:
//   ON  -> connect to the c2w-net relay (ws://localhost:8888) -> real internet.
//   OFF -> connect to a dead local port -> link stays down -> nothing leaves the
//          device; the VM is fully local/offline.
const _np = new URLSearchParams(location.search);
const _netPref = _np.get('net') || localStorage.getItem('ubuntu_net') || 'off';
const NET_ON = _netPref === 'on';
window.__NET_ON = NET_ON;                 // uvm.html reads this to reflect state + auto-DHCP

// Relay endpoint. In production (page served over HTTPS) we tunnel to a wss:// relay
// derived from the app's own hostname by convention — box.eths.dev -> relay.eths.dev —
// and tell Emscripten's socket layer to open a SECURE WebSocket (an HTTPS page can't use
// ws://). Local dev uses the plain ws relay on localhost:8888. Override anytime by setting
// window.__RELAY = 'host:port' before this runs.
const _tls = location.protocol === 'https:';
const _relay = window.__RELAY || (_tls ? location.hostname.replace(/^[^.]+/, 'relay') + ':443' : 'localhost:8888');
if (_tls) Module['websocket'] = { url: 'wss://' };   // -> wss://relay.<domain>:443 for the netdev socket

Module['arguments'] = [
    "-nographic",
    "-m", "768M",
    "-smp", "1",
    "-accel", "tcg,tb-size=256",
    "-machine", "pc",
    "-L", "/pack/",
    "-netdev", NET_ON ? `socket,id=vmnic,connect=${_relay}` : "socket,id=vmnic,connect=127.0.0.1:1",
    "-device", "virtio-net-pci,netdev=vmnic",
    "-kernel", "/vmlinuz",
    "-initrd", "/initrd.img",
    "-append", "console=ttyS0,115200 root=/dev/vda1 rw loglevel=4 apparmor=0 net.ifnames=0 virtio_net.napi_tx=false",
    "-drive", "if=virtio,format=qcow2,file=/jammy-min.qcow2",
    "-loadvm", "booted",
];
