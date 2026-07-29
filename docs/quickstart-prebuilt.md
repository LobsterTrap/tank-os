# Quick Start: Run tank-os From Published Images

This is the "just run it" path — no `make build`, no bootc-image-builder
invocation, no `config.toml`. Everything here pulls from the already-published
images:

| Image | Used for |
| --- | --- |
| `quay.io/redhat-et/tank-os-containerdisk:latest` | Contains a ready-to-boot `disk.qcow2` — extract it and boot with any hypervisor |
| `quay.io/redhat-et/tank-os:latest` | The bootc OS image itself — only needed for `bootc switch`/`bootc upgrade` on an existing bootc host |

All three published repos (`tank-os`, `tank-claw-openshell`,
`tank-os-containerdisk`) are public-read; no `podman login` required to pull.

## Extract the disk image

The containerdisk image is a `FROM scratch` wrapper around one file
(`/disk/disk.qcow2`, KubeVirt's convention) — `podman create` + `podman cp`
pulls it out without running the container:

```bash
podman create --name tank-os-extract quay.io/redhat-et/tank-os-containerdisk:latest
podman cp tank-os-extract:/disk/disk.qcow2 ./tank-os-disk.qcow2
podman rm tank-os-extract
```

This qcow2 was built with `--rootfs xfs` for `arm64` (see the Makefile's
`build-containerdisk` target) — it boots on Apple Silicon and on aarch64
Linux hosts directly. For x86_64, either build locally
(`make build-qcow2 ARCH=amd64`, see `docs/build.md`) or ask whoever publishes
images to also push an amd64-tagged containerdisk; a single tag can only hold
one architecture's disk.

The SSH keys and OpenClaw/OpenShell config already baked into `tank-os:latest`
came from whatever `config.toml` was used at containerdisk build time — check
with whoever published it, or expect to need your own build if you need a
different key.

## macOS (Apple Silicon) via QEMU

Same QEMU + HVF invocation as `docs/build.md`'s "Launch on macOS" section,
just pointed at the extracted qcow2 instead of a locally built one:

```bash
qemu-img resize ./tank-os-disk.qcow2 20G

qemu_share="$(brew --prefix qemu)/share/qemu"
cp "$qemu_share/edk2-arm-vars.fd" ./edk2-arm-vars.fd

qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=./tank-os-disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=./edk2-arm-vars.fd \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic
```

Requires `brew install qemu`. SSH once booted: `ssh -p 2222 openclaw@localhost`
(assuming the published image's baked-in key matches yours).

## Fedora Linux

Two paths, depending on whether the target machine already runs a bootc-based
OS:

**Already on a bootc host** (e.g. a prior tank-os VM, or plain
`fedora-bootc`) — no disk image needed at all, `bootc` handles the pull:

```bash
sudo bootc switch --apply quay.io/redhat-et/tank-os:latest
```

Reboots into tank-os in place. Future updates: `sudo bootc upgrade --apply`.

**Not yet a bootc host** (e.g. a regular Fedora Workstation/Server, or an
empty VM) — boot the extracted qcow2 directly with `virt-install`, which
Fedora ships by default:

```bash
sudo virt-install \
  --name tank-os \
  --memory 4096 \
  --vcpus 2 \
  --disk ./tank-os-disk.qcow2,format=qcow2,bus=virtio \
  --import \
  --os-variant fedora-unknown \
  --network network=default \
  --graphics none \
  --console pty,target_type=serial
```

Or use the repo's portable QEMU script (`examples/boot-tank-os-qemu.sh`) the
same way `docs/build.md`'s "Launch on Linux (QEMU)" section describes, again
pointing it at `./tank-os-disk.qcow2` instead of a fresh
`out-tank-os/qcow2/disk.qcow2`.

## Lima (macOS/Linux)

**Confirmed working** on Lima 2.2.0 / macOS (Apple Silicon, M3), 2026-07-28,
across all three of Lima's VM drivers. Ready-made manifests are at
`examples/lima/`:

| Manifest | Driver | Notes |
| --- | --- | --- |
| `tank-os-qemu.yaml` | QEMU | Works on macOS and Linux hosts alike; same HVF acceleration as the plain-QEMU recipe above |
| `tank-os-vz.yaml` | Apple `Virtualization.framework` | macOS only, no firmware files to manage; networked over vsock instead of usermode NAT |
| `tank-os-krunkit.yaml` | krunkit (libkrun) | macOS only; keeps the whole stack on the same hypervisor family this repo's own Podman-machine build path already uses |

All three produced identical guest behavior (cloud-init, hostname,
OpenClaw/OpenShell bring-up) — pick whichever driver is already installed;
there's no functional reason to prefer one over another for this image.

```bash
mkdir -p ~/.lima/_images
podman create --name tank-os-extract quay.io/redhat-et/tank-os-containerdisk:latest
podman cp tank-os-extract:/disk/disk.qcow2 ~/.lima/_images/tank-os-disk.qcow2
podman rm tank-os-extract

limactl start --name tank-os ./examples/lima/tank-os-vz.yaml --tty=false
limactl shell tank-os
```

(Swap in `tank-os-qemu.yaml` or `tank-os-krunkit.yaml` for a different
driver — only `vmType` differs between the three files.)

What actually happens, and what to expect:

- **`limactl start` exits non-zero and prints "DEGRADED."** This is
  harmless, not a failure to fix: Lima's health check requires its own
  `lima-guestagent` to be running in the guest for port-forwarding/mount
  status, and tank-os doesn't ship that agent. The VM itself boots and is
  fully usable — `limactl list` shows `STATUS=Running`, and
  `limactl shell tank-os` / plain `ssh` both work immediately. Ignore the
  exit code and DEGRADED banner.
- **Cloud-init runs cleanly and both cloud-init "layers" coexist.** Lima
  injects its own NoCloud data (creating a `lima` user, its SSH key, and a
  hostname) on top of tank-os's baked-in `cloud-init`/`sshd` — both apply
  without conflict, confirming this base image needs no Lima-specific
  changes to work as an "arbitrary" (non-Lima-aware) guest.
- **Hostname becomes `lima-tank-os`, not `tank`.** Lima's own cloud-init
  hostname module runs after tank-os's baked-in `/etc/hostname`
  and wins — same "last cloud-init wins" behavior already documented for
  the OpenShift Virtualization path's per-VM hostnames.
- **One pre-existing, unrelated failed unit:** `cloud-init-main.service`
  shows `failed` in `systemctl --failed` — this is Fedora's legacy
  single-process cloud-init compatibility unit; the real boot-stage units
  (`cloud-init-local`, `cloud-init-network`, `cloud-config`, `cloud-final`)
  all report `active`/`exited` normally, so the system is functionally
  fine despite `systemctl is-system-running` printing `degraded`.
- **OpenClaw/OpenShell come up exactly as documented for QEMU.**
  `openclaw.service` runs through the same `bootstrap-openclaw` →
  `bootstrap-openshell-sandbox` sequence as `docs/openshell.md` describes,
  including the known `openshell sandbox create` CLI-hang (the sandbox
  reaches `Phase: Ready` well before the wrapping `timeout 600` process
  exits) — this is the same pre-existing quirk on Lima as on bare QEMU, not
  something Lima introduces.

Verify from inside the guest:

```bash
limactl shell tank-os -- sudo -u openclaw \
  env XDG_RUNTIME_DIR=/run/user/1000 openshell sandbox get tankos-openclaw
```
