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
const _relay = (window.__RELAY || 'localhost:8888');   // deploy: point at your relay host

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
