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

- **Phase 2 — the graphical desktop — BLOCKED at the engine level (R&D archived).**
  Two independent paths both hit fundamental qemu-wasm limitations:
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
  - **Verdict:** cracking the desktop needs research-grade patching of qemu-wasm's C
    internals (its ffi/device emulation, or the Emscripten GL setup) — days-to-weeks,
    uncertain. Matches the prior art: no one has publicly shipped amd64 graphical-in-browser.

## Recovery / history

- `pre-rebuild` tag — the original portfolio site.
- `scrapped-ethanos` branch — the earlier EthanOS "WebOS" experiment.
