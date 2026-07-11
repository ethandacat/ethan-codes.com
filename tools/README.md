# Build pipeline — Ubuntu 22.04 (amd64) → browser bundle

These scripts build the WebAssembly VM bundle (`qemu-system-x86_64.wasm` + packed
rootfs/kernel/BIOS + Emscripten JS glue) that boots Ubuntu 22.04 in the browser.
They run inside **WSL2 Ubuntu-22.04** with a native **Docker Engine** (not Docker
Desktop). The generated bundle lands in `public/vm/` (git-ignored; ~190 MB).

## One-time host setup (in WSL2, as root)

```bash
# Docker Engine (native, in WSL2 — Docker Desktop is flaky headless):
apt-get update && apt-get install -y docker.io
systemctl enable --now docker

bash tools/get-c2w.sh        # install the container2wasm `c2w` converter
bash tools/setup-buildx.sh   # install buildx + a docker-container BuildKit builder
bash tools/fix-dns.sh        # daemon DNS 8.8.8.8/1.1.1.1 + host-net builder
```

## Build

```bash
bash tools/build-vm.sh       # c2w --to-js ubuntu:22.04 → /root/vm-out → public/vm/
```

## Gotchas we hit (why each script exists)

- **Docker Desktop won't start headless** → run native Docker Engine in WSL2.
- **c2w needs BuildKit/buildx**; `docker.io` ships only the legacy builder → `setup-buildx.sh`.
- **Nested BuildKit container can't resolve DNS** (WSL stub resolver) → `fix-dns.sh`
  sets daemon DNS + recreates the builder with `network=host`.
- **c2w v0.8.4 points at the old `ktock/container2wasm` repo** (no `v0.8.4` tag; the
  project moved to the `container2wasm` org) → `build-vm.sh` passes
  `--build-arg SOURCE_REPO=https://github.com/container2wasm/container2wasm`.
- **systemd makes WSL `/tmp` a tmpfs** wiped on distro restart → build outputs to
  `/root`, then copies into `public/vm/`.

## Serve

The bundle needs cross-origin isolation (COOP/COEP → SharedArrayBuffer). Use the
repo's `server.mjs` (`npm run serve`) and open `/vm/`.
