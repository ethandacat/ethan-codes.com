# Ubuntu 22.04 LTS, in the browser

**Goal:** boot a genuine, unmodified **Ubuntu 22.04 LTS amd64** with a **graphical
desktop** and **working networking** (`apt install`, `curl`), running entirely in a
web browser via WebAssembly full-system emulation.

## The hard constraint

Browsers offer no native virtualization (no KVM), no raw syscalls, and no raw TCP
sockets. So this is **software full-system emulation of an x86-64 machine compiled
to WebAssembly**, fed a real disk image, with its framebuffer painted to a `<canvas>`
and its network tunneled through a WebSocket→TCP proxy. It will be **slow** — that is
inherent to the browser, not a bug we can engineer away. The target is an impressive,
*real* demo, not a daily driver.

## Chosen shape

- **Fidelity:** exactly Ubuntu 22.04 amd64 (64-bit), unmodified image.
- **Interface:** full GUI desktop rendered to canvas.
- **Networking:** yes — real internet via a proxy.
- **Engine:** amd64-capable emulator compiled to WASM (QEMU-TCG-WASM vs Bochs-WASM /
  container2wasm) — **TBD, pending the Phase-0 research.**

## Phases (each ends in something that visibly works)

- **Phase 0 — Foundation & proof-of-life.** Pick the engine. Scaffold the app. Boot a
  *tiny* amd64 Linux (busybox/alpine) to a canvas. Proves the whole pipeline.
- **Phase 1 — Ubuntu to a console.** Real Ubuntu 22.04 amd64 disk image boots to a text TTY.
- **Phase 2 — The desktop.** X + a desktop environment painted to canvas; keyboard + mouse input.
- **Phase 3 — Networking.** WebSocket→TCP proxy so `apt`/`curl` reach the internet + DNS.
- **Phase 4 — Persistence & speed.** IndexedDB write overlay, snapshot save/restore,
  HTTP-range streaming of the disk image so it doesn't download multi-GB up front.
- **Phase 5 — Ship.** Host the image (range-capable static host) + the net proxy (small server).

## Progress log

- **Phase 0–1 — DONE.** Real **Ubuntu 22.04.5 LTS amd64** boots to an interactive
  shell in the browser, 2 GB RAM, via a reproducible pipeline (`tools/`, `server.mjs`).
  Toolchain: Docker Engine in WSL2 → buildx → `c2w --to-js ubuntu:22.04`.
  Hard limit found: **wasm32 caps guest RAM at 2047 MB** (3 GB needs wasm64/MEMORY64).

- **Phase 2 — the graphical desktop — ✅ DONE. IT WORKS.** A real amd64 Ubuntu
  X desktop (Xorg + openbox WM + xterm) renders **live in the browser** via Path C.
  The winning recipe (all in `public/vm-fb/` + `tools/`):
  1. **fb kernel** — `DRM_BOCHS`+`DRM_FBDEV_EMULATION`+`FRAMEBUFFER_CONSOLE` (Dockerfile.fb)
     → `/dev/fb0` on the default VGA. Run with `-nographic` (keeps VGA + wires serial).
  2. **Memory** — guest RAM ≤ ~1 GB (594 MB rootfs must fit the 3000 MB wasm heap).
  3. **Device access** — patched c2w's `create-spec` (`generateSpec`) to set an
     allow-all device cgroup + add `/dev/fb0`,`/dev/vdb` nodes; built via
     `c2w --assets <patched-source>`. Fixes the runc-sandbox `EPERM`.
  4. **Channel** — a **2nd virtio-blk disk** backed by Emscripten-FS `/tmp/fbdisk`
     (pre-created in `preRun`). Guest loops `dd if=/dev/fb0 of=/dev/vdb`; JS reads
     `/tmp/fbdisk` from `Module.FS` and blits (BGRX→RGBA) to canvas.
  5. **Input to the VM** — inject via `Module.pty.ldisc.writeFromLower(bytes)`
     (browser terminal focus was unreliable; this is 100% reliable).
  6. **X** — `mknod /dev/tty0..2`; Xorg fbdev on `/dev/fb0`; `openbox` + `xterm`.
  Historical R&D below (both engine "walls" turned out to be OOM + serial-routing +
  container device cgroup, not real engine limits):
  - **Path A — SDL → canvas.** Recompiled qemu-wasm *with* SDL2 (compiles + links —
    likely a first). But Emscripten can't give QEMU's render *pthread* a WebGL context:
    no-OffscreenCanvas → `createShader` on undefined; OffscreenCanvas-transfer →
    main-thread `eglCreateContext` on a transferred canvas; `OFFSCREEN_FRAMEBUFFER` →
    worker `GLctx` never current. GL-on-pthreads thread-affinity wall.
  - **Path C — guest framebuffer → 9p → canvas.** 9p channel works with
    `security_model=none`. The framebuffer kernel (`DRM_BOCHS` + `DRM_FBDEV_EMULATION`
    + `FRAMEBUFFER_CONSOLE`) **boots fine** — the earlier "BigInt crash" was a *red
    herring: pure OOM* (594 MB desktop rootfs + 2 GB guest RAM > 3000 MB wasm heap;
    drop guest RAM to ~1 GB and it boots). The **real wall**: qemu-wasm **hangs during
    QEMU device-realization whenever *any* display device is present** — `-vga std`,
    `-device bochs-display` (romfile disabled), and `-device virtio-gpu-pci` all hang
    the boot before a single serial line; remove the display device and it boots to a
    shell. So no `/dev/fb0` is obtainable. Same fundamental layer as Path A: qemu-wasm
    has no working display path — by *device realization* and by *GL rendering*.
  - **Verdict (Path A):** the SDL/GL route needs research-grade Emscripten-GL work.
  - **Path C is actually VIABLE — the "engine walls" were misdiagnoses.** The blockers
    were mundane: (1) OOM (drop guest RAM to ~512 MB–1 GB so 594 MB rootfs + guest fit
    the 3000 MB heap); (2) serial routing — `-vga std -display none` doesn't wire
    serial to stdio like `-nographic` does, so the guest *looked* hung while booting
    fine; (3) `-nographic` keeps the default VGA, so the fb kernel registers **`fb0`
    at 1280×800×32 (stride 5120)** — `/dev/fb0` just needs a manual `mknod c 29 0`
    (no udev in the minimal container). `cat /dev/fb0` works.
  - **Channel:** 9p/virtfs is rejected by qemu-wasm (`permission denied`, all options).
    Pivoted to a **second virtio-blk disk** backed by an Emscripten-FS file
    (`-drive file=/tmp/fbdisk`, pre-created in `preRun`): guest `dd`s `/dev/fb0` →
    `/dev/vdb`, JS reads `/tmp/fbdisk` from `Module.FS` and blits to canvas.
  - **Blitter + channel proven at the JS layer:** `public/vm-fb/index.html` reads the
    4,096,000-byte channel disk out of `Module.FS` and blits (verified).
  - **FINAL obstacle found — the c2w runc container's device cgroup.** Inside the
    guest we're in the sandboxed container; raw device reads fail with **`EPERM`
    (Operation not permitted)** on `/dev/fb0` *and* `/dev/vdb`, even as root with
    valid nodes (`254:16`). So `dd if=/dev/fb0 of=/dev/vdb` silently no-ops and the
    channel disk stays zero. The framebuffer itself is real (`fb0` 1280×800, sysfs
    readable) — the sandbox gates raw device access.
  - **`nsenter` escape is also blocked** (`reassociate to namespace 'ns/pid' failed:
    Operation not permitted`) — the container has no `CAP_SYS_ADMIN`. So there's no
    runtime bypass; the fix must be at **container-config/build time**.
  - **Next step (one build):** make the c2w guest run with raw device access — a
    privileged/permissive device cgroup, or explicit `/dev/fb0` + channel-disk grants,
    or run the capture as the container's *own* entrypoint (which owns its devices)
    rather than a nested shell. Then `dd /dev/fb0 -> /dev/vdb` (loop) → blit →
    `startx` (openbox/xterm baked in) for a real desktop. Everything else is proven:
    framebuffer exists, JS channel reads the disk, blitter renders.

## ✅ SOLVED — full styled Ubuntu 22.04 desktop renders in the browser

All remaining walls fell; every one was mundane. The desktop is **live and visible**:
aubergine root, a **tint2 top panel** (taskbar + live clock), **openbox** window
decorations (title bar + min/max/close), and a **working xterm** printing
`Linux … x86_64 … GNU/Linux` + `PRETTY_NAME="Ubuntu 22.04.5 LTS"`.

The four fixes that made it work:

1. **Container device cgroup → patch `create-spec`.** `nsenter`/runtime bypass is
   blocked (no `CAP_SYS_ADMIN`), so patch `cmd/create-spec/main.go`'s `generateSpec()`
   to allow-all devices (`LinuxDeviceCgroup{Allow:true, Access:"rwm"}`) and add
   `/dev/fb0` (c 29 0) + `/dev/vdb` (b 254 16) nodes. Fed to c2w via
   `--assets <patched-src>` (becomes `--build-context assets=…`). Now
   `dd if=/dev/fb0 of=/dev/vdb` works inside the guest and the JS channel fills.

2. **fbdev ShadowFB OFF.** With the default ShadowFB *on*, X renders to a RAM shadow
   and only lazily flushes to `/dev/fb0`, so the `dd` capture sees black / can even
   block. `xorg.conf` `Device` section `Option "ShadowFB" "off"` → X writes **directly
   to `/dev/fb0`**, so the capture loop sees live X output. This was the single fix
   that turned "clients run but canvas is black" into a rendering desktop.

3. **No `feh` on the 4K wallpaper.** Imlib2 scaling a 4096×2304 image under TCG hangs
   for minutes (looks deadlocked). Use `xsetroot -solid '#2C001E'` (the classic Ubuntu
   aubergine) — instant. (A pre-scaled 1280×800 wallpaper would also work; bake it.)

4. **xterm needs a core bitmap font.** `-fa 'Ubuntu Mono'` (Xft/TrueType) maps a window
   but renders **blank white** under fbdev here. `-fn 9x15` (core bitmap) renders text
   perfectly. Colours via `-bg '#300A24' -fg '#EEEEEC'`.

Other gotchas: X comes up in ~2 s (`X -nolisten tcp -novtswitch -config … vt1`); the
serial-console shell **queues typed-ahead input** and its **stdout render lags** — trust
the framebuffer (`Module.FS.readFile('/tmp/fbdisk')`) and screenshots over `.xterm-rows`
DOM reads. To repaint after an external `/dev/fb0` write, `xsetroot` to a *different*
colour then back + `xrefresh` (same-colour xsetroot is a no-op). Reproducible bring-up:
`scratchpad/desktop2.sh` (base64-inject → `bash`).

**Auto-boot is baked (done).** `/usr/local/bin/desktop.sh` is the container CMD, and
`public/vm-fb/index.html` auto-starts the blit — so loading the page goes: Linux boot
console → `[ OK ] Starting X server…` → X → Jammy wallpaper → top panel + terminal,
with no interaction. desktop.sh order matters: **openbox must start before feh** (openbox
clears the root once at startup and would wipe the wallpaper), and it ends with a
re-feh + `xrefresh` repaint loop because cold-boot client windows can map without
painting. There's a top panel (taskbar + clock) and a **bottom dock** (centered app
launcher: Terminal / Files / Calculator / Image Viewer).

**tint2 launcher icons — use absolute PNG paths.** The old left dock was blank not
because icons were missing but because tint2's icon-*theme* lookup failed. Yaru ships
48×48 PNGs at `/usr/share/icons/Yaru/48x48/apps/` (utilities-terminal, system-file-manager,
accessories-calculator, multimedia-photo-viewer, …). Point each `.desktop` `Icon=` at the
**absolute PNG path** and tint2 renders them. (Yaru's SVGs are a red herring — tint2 may
lack SVG support, but the PNGs are right there.)

**The VM is NOT throttled by tab visibility — a myth I chased for a while.** qemu-wasm
runs QEMU in **Web Workers** (SharedArrayBuffer threads); instrumenting the main thread
showed `requestAnimationFrame` and `setTimeout` are called **0 times/sec** — the main
thread does almost nothing. Web Workers are never throttled by a hidden tab, so the guest
runs full-speed whether the tab is focused, backgrounded, or minimized (proven: the whole
desktop booted to completion with `document.hidden===true`). What *does* throttle when
hidden is only the **canvas blit** (a main-thread `setInterval`) — i.e. what you SEE, not
what the VM DOES. It resumes the moment the tab is visible again, so it's cosmetic. (The
index.html silent-audio + worker-rAF shims are harmless belt-and-suspenders but were
solving a non-problem — the real fixes were elsewhere.)

**Panels/dock don't paint on first launch — relaunch after the boot settles.** tint2
panel windows map during the cold-boot CPU storm and their first Expose gets starved, so
they stay invisible even though the process is running. `xrefresh` does NOT fix it; a
**relaunch** (kill + restart tint2) once the guest is idle (~12 s in) makes them paint.
xterm/openbox (managed) windows repaint on their own. Also: a tint2 panel needs a **fixed
pixel `panel_size`** dimension (e.g. `340 60` / `58 224`) — `panel_size = 0 …` is a
zero-size (invisible) panel. Dock launcher icons: absolute Yaru PNG paths (see above).

**BOTTOM-edge windows don't flush; LEFT and TOP do.** A tint2 panel at `bottom` maps at
the right geometry (`1280x50+0+742`) but X won't reliably flush its pixels to `/dev/fb0`
on this fbdev/qemu-wasm setup. So the launcher is a **left vertical dock**
(`panel_position = center left vertical`, `panel_size = 58 224`) — Ubuntu's signature
position. Note: colour-based dock detection from JS is unreliable because Jammy's wallpaper
is dark-aubergine on the left — verify the dock visually (force a blit, then screenshot).

**⚠️ UNRESOLVED — client-window flushing is non-deterministic.** The core open problem: on
this qemu-wasm fbdev X server, the **root window (wallpaper) always flushes to `/dev/fb0`,
but CLIENT windows (panels, dock, terminal) do not reliably** — they map at the correct
geometry and their processes run, but their pixels often never reach the framebuffer. It
works on *some* boots/sessions (captured full desktops with terminal + panels multiple
times) and not others — a per-X-instance coin flip. Reproduce/verify with a green test
window: `xterm -bg green &` then read `/tmp/fbdisk` for green pixels (0 = didn't flush).
**Ruled out** (none fixed it): `ShadowFB` on/off, `xcompmgr` compositor, disabling the
`Composite` extension, the `Modes` mode-set line, window size (small vs near-full-screen),
launch timing (cold-boot vs settled X), and every repaint trigger (`xrefresh`,
`openbox --restart`, relaunching tint2, mapping fresh windows). Only the root flushes.
Mitigations baked: left dock (left edge is the most reliable), a 4× relaunch loop in
desktop.sh to improve the odds. Likely needs **engine-level work** (the qemu-wasm fbdev
driver's damage/flush path) or a different display path (virtio-gpu — currently hangs the
qemu-wasm boot). A wallpaper-only desktop is 100% reliable; the panels/dock are best-effort.

**Next milestone — GUI input.** Nothing feeds mouse/keyboard into X yet (only the serial
console). Wiring browser pointer/key events → guest `/dev/input/event*` over a channel is
what makes the desktop actually usable; higher value than WebGPU (which can't speed up
TCG CPU emulation and is blocked anyway by qemu-wasm's display-device-realization hang).

## ★ NEW DIRECTION — real Ubuntu image + FULL qemu-wasm (supersedes the c2w desktop)

The c2w desktop above works but it's a *container* (c2w's own kernel + a runc-style
init running our `desktop.sh`), assembled bottom-up, with the unresolved client-window
flush problem. Decision: **start from the real Ubuntu Minimal cloud image and boot its
own kernel + systemd**, then modify it down — top-down instead of bottom-up.

**Why c2w's wasm can't do it.** c2w ships a *minimized* `qemu-system-x86_64.wasm`
(`configure --without-default-features`). It boots **only** c2w-packaged images and dies
with `RuntimeError: function signature mismatch` (in the pthread worker, before any guest
instruction) on **qcow2**, on **`-initrd`**, and on a real Ubuntu rootfs. It is a dead end
for booting the genuine image.

**The fix — build a FULL qemu-wasm.** Same engine (ktock/qemu-wasm), Docker build, but:
- `docker build -t buildqemu - < Dockerfile` (base = emsdk 3.1.50 + glib/pixman/zlib/libffi
  cross-compiled to wasm). Patch: zlib.net 404s → fetch zlib from the GitHub release.
- Build from a **writable copy** of the source in-container (`cp -a /qemu /qemu-build`), not
  the `:ro` mount, so meson can fetch wrap subprojects.
- Configure with **default features** (NO `--without-default-features`) so qcow2 + the
  initrd loader + all block drivers link in; keep `--enable-fdt` (x86_64-softmmu *requires*
  fdt — the dtc subproject auto-downloads into the writable copy); `--with-coroutine=fiber`,
  `--enable-virtfs`; `EXTRA_CFLAGS … -sTOTAL_MEMORY=3000MB -sASYNCIFY=1 -sPROXY_TO_PTHREAD=1
  -sEXPORT_ES6=1 -sWASM_BIGINT -sMALLOC=mimalloc`; ldflags export `getTempRet0,setTempRet0,
  addFunction,removeFunction,TTY,FS`.
- Output: `qemu-system-x86_64` (→ `out.js`), `.wasm` (49 MB), `.worker.js`; then
  `file_packager.py qemu-system-x86_64.data --preload /pack` bakes SeaBIOS + option ROMs
  (`bios-256k.bin`, `vgabios-stdvga.bin`, `kvmvapic.bin`, `linuxboot_dma.bin`,
  `efi-virtio.rom`) into `.data` (found via `-L /pack/`). Reproduce: `scratchpad/build_qemu.sh`
  + `scratchpad/package_deploy.sh`. Build must run as **`wsl.exe -u root`** (Docker daemon +
  file perms; passwordless `sudo` is unavailable, but root WSL is).

**Boot recipe (direct-kernel, serial-guaranteed).** GRUB/BIOS output goes to VGA, not
serial, so bypass GRUB and boot Ubuntu's own kernel straight to `ttyS0`:
```
-nographic -m 768M -accel tcg,tb-size=256 -machine pc -L /pack/ -nic none
-kernel /vmlinuz -initrd /initrd.img
-append "console=ttyS0,115200 root=/dev/vda1 rw loglevel=7"
-drive if=virtio,format=qcow2,file=/jammy-min.qcow2
```
`-nic none` because slirp isn't compiled in (add it later for networking). The 305 MB qcow2
is fetched + `FS.writeFile` into MEMFS at runtime (sparse driver only faults touched
clusters, so it fits the 3 GB heap) — modify the disk offline, re-serve, no rebuild. Frontend:
`public/vm-fb/uvm.html` + `uvm-arg.js`.

**Offline image-modification workflow (the whole point of "modify it slowly").** As root in
WSL: `qemu-nbd --connect=/dev/nbd0 -f qcow2 jammy-min.qcow2` → `mount /dev/nbd0p1` (GPT p1 =
root ext4; p14 BIOS-boot, p15 EFI) → edit → `umount` → `qemu-nbd --disconnect`. Applied so
far (`scratchpad/mod_qcow2.sh`): **autologin root on ttyS0** (serial-getty drop-in), disable
cloud-init, mask snapd/ssh/multipath/lvm2/networkd-wait (TCG boot speed), `multi-user.target`,
MOTD. Kernel/initrd extracted from the image's `/boot` (`5.15.0-1103-kvm`).

**Status — real Ubuntu 22.04 runs in the browser, and now restores INSTANTLY.**
Verified end-to-end: kernel → initramfs → ext4 `/dev/vda1` → systemd 249.11 → **interactive
`root@ubuntu-wasm` shell** (typed `id`/`uname` in-browser, got `uid=0` / `Linux x86_64`).

**Autologin fix (the one that stuck):** under 20×-slow TCG, `login(1)`'s PAM session setup
exceeds its 60s timeout and the getty restart-loops. Also `serial-getty@ttyS0` BindsTo
`dev-ttyS0.device`, which udev takes >90s to activate under TCG. Fix = a standalone
`console-autologin.service` (After=basic.target, no device dep) that runs
`agetty --autologin root --login-program /usr/local/bin/ccshell` where `ccshell` just
`exec bash --login -i` — i.e. agetty's solid tty setup but **no `login(1)` at all**, so no
timeout. Plus: mask the network/NTP/online/resolved waiters + disable `/etc/update-motd.d/*`
(network hangs) + `apparmor=0` on the cmdline (AppArmor profile-load is 10+ min under TCG).

**Instant boot via pre-booted snapshot (the big win).** A cold TCG boot is ~10 min; nobody
waits that. So: build a NATIVE qemu-8.2 from the same source (`--with-coroutine=ucontext`;
the fork defaults to emscripten `fiber` which won't link natively), boot it TCG with args
**byte-identical** to the wasm, and `savevm booted` — storing a 187 MB RAM+device snapshot
*inside* the qcow2. The browser fetches that qcow2 and runs with `-loadvm booted`: it skips
the entire boot and lands on the live shell in seconds (verified: `uptime` shows "up 0 min",
commands run). Compatibility rule: the restore args (`-m 768M -smp 1 -machine pc`, the
`-append` string, and the QEMU-8.2 BIOS in `-L /pack/`) must exactly match the save, or
`-loadvm` rejects the state. Reproduce: `scratchpad/make_snapshot.sh` (save) +
`scratchpad/restore_test.sh` (verify). Served files: `jammy-min.snap.qcow2` (snapshot,
~505 MB) + `jammy-min.clean.qcow2` (pristine, for re-snapshotting after image edits).

**Re-snapshot workflow after editing the image:** edit `jammy-min.clean.qcow2` offline
(qemu-nbd), then re-run `make_snapshot.sh` to regenerate `jammy-min.snap.qcow2`. The disk
edits and the RAM snapshot stay consistent because savevm captures both together.

Next: networking (rebuild wasm with slirp + a WebSocket→TCP proxy → `apt`/`curl`), then
write-persistence (IndexedDB overlay), then optionally a GUI desktop.

## Recovery / history

- `pre-rebuild` tag — the original portfolio site.
- `scrapped-ethanos` branch — the earlier EthanOS "WebOS" experiment.
