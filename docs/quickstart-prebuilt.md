# Quick start: run tank-os from published images

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
podman create --replace --name tank-os-extract quay.io/redhat-et/tank-os-containerdisk:latest
podman cp tank-os-extract:/disk/disk.qcow2 ./tank-os-disk.qcow2
podman rm tank-os-extract
```

All three published tags (`tank-os`, `tank-claw-openshell`,
`tank-os-containerdisk`) are real multi-arch manifest lists covering both
`arm64` and `amd64` — `podman pull`/`create` above automatically gets the
disk matching whatever machine you run it on, no `ARCH=` flag or separate
tag needed. (This wasn't always true: earlier in this repo's history these
were single-arch images built only from an Apple Silicon Mac, which broke
silently on amd64 targets — see `docs/openshift-virtualization.md`'s "What
broke on a real cluster" for how that surfaced and got fixed. If you're
publishing new versions of these images yourself, build and push both
architectures and merge them with `podman manifest create`/`push --all`
before publishing, or you'll reintroduce the same problem for the next
architecture that isn't yours.)

The SSH key already baked into the published qcow2 belongs to whoever built
and pushed it — you almost certainly don't have that private key, so plain
`ssh openclaw@...` against the shared image will just hang/refuse. See "Use
your own SSH key" below before trying to connect.

## Use your own SSH key instead of the baked-in one

A shared, published disk image can only have one SSH key baked in at build
time (via `config.toml`'s `[[customizations.user]]`, see `docs/build.md`) —
fine for a private build, useless for anyone else pulling the same
published image. The fix isn't to rebuild the image per person (that
defeats the point of publishing one shared containerdisk); it's to inject
your own key at **boot time** instead, via a small cloud-init NoCloud seed
ISO attached alongside the disk.

Confirmed this holds even with **no baked-in key at all**: built a qcow2
from a `config.toml` with an empty `[customizations]` block (no
`[[customizations.user]]` entry, so `~openclaw/.ssh/authorized_keys` doesn't
exist until cloud-init creates it) and deployed it on OpenShift
Virtualization with only `deploy/base/virtualmachine.yaml`'s
`cloudInitNoCloud` supplying a key — SSH worked immediately, same as every
other test in this doc. The baked-in key was never load-bearing; cloud-init
alone is sufficient. This is the same mechanism Lima uses to give every
instance its own key without baking anything into its shared
base images, and the same `cloudInitNoCloud` shape already used for
per-user VMs in `deploy/base/virtualmachine.yaml`.

Reuse this repo's existing cloud-config (already shaped for the pre-existing
`openclaw` user — cloud-init adds your key to that user's
`authorized_keys`, it doesn't need to recreate the user):

```bash
# If running outside of the repo, download the example from GitHub
curl -L -o user-data https://github.com/LobsterTrap/tank-os/raw/refs/heads/main/examples/cloud-init/openclaw-user-data.yaml

# If running from the repo clone, use the local copy
#cp examples/cloud-init/openclaw-user-data.yaml ./user-data
python3 -c "
import pathlib
key = pathlib.Path.home().joinpath('.ssh/id_ed25519.pub').read_text().strip()
p = pathlib.Path('user-data')
p.write_text(p.read_text().replace('ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-os', key))
"

cat > ./meta-data <<'EOF'
instance-id: tank-os-quickstart
local-hostname: tank
EOF
```

`user-data`/`meta-data` are all you need from here — `vfkit` (below) and
`virt-install` (Fedora Linux, below) both take these two files directly via
a `--cloud-init` flag and build their own seed image internally. Only the
plain-QEMU path needs a seed ISO built by hand; that step is in the QEMU
section below since it's specific to that path.

## macOS (Apple Silicon) via vfkit

[vfkit](https://github.com/crc-org/vfkit) drives Apple's own
`Virtualization.framework` directly — no OVMF firmware file to manage, no
`-accel hvf`/Objective-C fork footguns (see the QEMU section below), and no
seed ISO to build by hand (`--cloud-init` takes the `user-data`/`meta-data`
files straight). `brew install vfkit` is the only host package needed.
**Requires macOS 13 (Ventura) or newer** — `Virtualization.framework`'s EFI
boot support (`--bootloader efi`) isn't available on older macOS releases.

The one thing `Virtualization.framework` doesn't support is qcow2 — only
raw and ISO images — so the extracted disk needs a one-time conversion.
Rather than adding a second Homebrew package (`qemu-img` only ships bundled
inside the full ~700MB `qemu` formula), reuse the `podman` you already have
for extracting the containerdisk, and run the conversion in a disposable
Fedora container:

```bash
podman run --rm -v "$PWD":/data registry.fedoraproject.org/fedora-minimal:latest \
  bash -c "microdnf install -y qemu-img -q && qemu-img resize /data/tank-os-disk.qcow2 20G && qemu-img convert -p -O raw /data/tank-os-disk.qcow2 /data/tank-os-disk.raw"
```

The published containerdisk's qcow2 isn't pre-sized to 20G, so the resize
has to happen before conversion here — same requirement as the QEMU section
below, just folded into this disposable container instead of a separate
host-installed `qemu-img` step.

The result is a sparse file — `ls -la` reports the full 20G, but `du -h`
shows only the actual data (macOS's APFS handles the sparseness natively,
same as the doc's earlier note on avoiding qcow2 replacements elsewhere).

Boot it:

```bash
nohup vfkit \
  --cpus 2 --memory 4096 \
  --bootloader efi,variable-store=./vfkit-efi-vars,create \
  --device virtio-blk,path=./tank-os-disk.raw \
  --device virtio-net,nat,mac=52:54:00:70:2b:71 \
  --device virtio-rng \
  --cloud-init ./user-data,./meta-data \
  --device virtio-serial,logFilePath=./console.log \
  --pidfile ./vfkit.pid \
  > vfkit.log 2>&1 &
disown
```

Uses the same `user-data`/`meta-data` files from "Use your own SSH key"
above — no seed ISO build step needed, vfkit's `--cloud-init` flag builds
one internally. `--device virtio-serial,logFilePath=./console.log` runs
headless by default (vfkit only shows a GUI window if you pass `--gui`
*and* add a `virtio-gpu` device); tail `console.log` to watch boot.

**`vfkit` runs in the foreground and blocks until the VM halts — the final
`INFO[0000] waiting for VM to stop` line is normal, not a sign anything is
wrong or shutting down.** It just means vfkit's main thread has finished
setup and is now parked waiting for the VM to exit. Run it with `nohup ...
&` (as above) to get your shell back immediately; `vfkit.log` keeps
capturing that same startup log if you want to check it later.

**Finding the guest's IP — and a red herring to ignore:** `virtio-net,nat`
hands the guest a real, directly-routable IP from the host (no `hostfwd`
port-forwarding needed, unlike QEMU's usermode networking). Tail
`console.log`; once cloud-init brings the network up you'll see something
like:

```text
enp0s1: 192.168.64.2 fdff:24e2:4235:b92e:5054:ff:fe70:2b71
Try contacting this VM's SSH server via 'ssh vsock%4294967295' from host.
```

**Ignore the `ssh vsock%...` line** — that's `systemd-ssh-generator`, a
newer systemd feature that offers to expose sshd over AF_VSOCK
automatically. It needs a `virtio-vsock` device wired up between host and
guest to actually work, which this vfkit invocation doesn't attach (see
`vfkit --device` above — we only added `virtio-blk`/`virtio-net`/
`virtio-rng`/`virtio-serial`). Pasting that line verbatim into a macOS
terminal, as you found, just fails to resolve as a hostname — it's not
meant to be typed as-is outside a properly configured vsock+SSH setup. Use
the plain IPv4 address on the line above it instead:

```bash
ssh openclaw@192.168.64.2   # substitute the address enp0s1 actually printed
```

That address is also recorded in `/var/db/dhcpd_leases` on the host if you
need to look it up again later, but it's simplest to just read it off
`console.log`.

Opening the OpenClaw dashboard directly at that IP (`http://192.168.64.2:18789/`)
will fail with a browser secure-context error — see `docs/cli.md`'s
"Browser secure-context requirement" for why, the SSH-tunnel fix, and a
workaround if your network blocks SSH local port-forwarding to that port.

**Verified on macOS/aarch64 (M3), 2026-07-30:** clean boot with no PCI
option-ROM/TPM log noise at all (Apple's EFI implementation doesn't probe
PCI option ROMs the way OVMF does — see the QEMU section's note on that),
`systemctl is-system-running` reports `running`, SSH via the printed
DHCP address worked immediately using a key supplied purely through
`--cloud-init`.

**Checking whether it's running, and stopping it:** unlike QEMU/libvirt,
`vfkit --help` has no built-in `list`/`stop` subcommand — the VM's
lifecycle is tied directly to the `vfkit` process itself (per the
project's own docs: it starts when `vfkit` starts and stops the instant
`vfkit` exits, whether via `Ctrl+C` or `kill`). That's what `--pidfile
./vfkit.pid` above is for, instead of hunting for the process with
`pgrep` after the fact:

```bash
# check status:
ps -p "$(cat vfkit.pid)"

# stop it (only once ps above confirms that pid is actually vfkit):
ps -p "$(cat vfkit.pid)" -o comm= | grep -q vfkit && kill "$(cat vfkit.pid)"
```

The `ps ... | grep -q vfkit &&` guard matters because a stale `vfkit.pid`
left over from a previous run can point at an unrelated process the OS has
since reassigned that PID to — checking the command name first avoids
sending `kill` to the wrong target. `kill` here sends SIGTERM, which vfkit
treats as a graceful stop request (`RequestStop()`, giving the guest OS up
to 5 seconds to shut down cleanly before forcing it off) — not an abrupt
power-pull. Prefer `ssh openclaw@<ip> sudo poweroff` when the guest is
reachable regardless, since it lets the guest shut down on its own terms
without depending on vfkit's timeout; fall back to the `kill` above (or
`pgrep -fl vfkit` if you forgot `--pidfile`) when SSH isn't available.

## macOS (Apple Silicon) via QEMU

QEMU works too, and is documented here for completeness / as a fallback if
`vfkit` isn't an option — but it's a heavier dependency (~700MB via
`brew install qemu`) and has a couple of macOS-specific rough edges (see
the notes after the command). Same QEMU + HVF invocation as
`docs/build.md`'s "Launch on macOS" section, just pointed at the extracted
qcow2 instead of a locally built one:

```bash
qemu-img resize ./tank-os-disk.qcow2 20G

qemu_share="$(brew --prefix qemu)/share/qemu"
cp "$qemu_share/edk2-arm-vars.fd" ./edk2-arm-vars.fd
```

Unlike `vfkit`/`virt-install`, plain QEMU has no built-in cloud-init
support, so the `user-data`/`meta-data` from "Use your own SSH key" above
need to be packed into a `cidata`-labeled seed ISO by hand first — pick
whichever tool you already have:

```bash
# Linux, if cloud-utils/cloud-image-utils is installed:
cloud-localds seed.iso user-data meta-data

# Linux or macOS, if genisoimage/mkisofs/cdrtools is installed:
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data

# macOS, no extra installs needed (built-in hdiutil):
mkdir -p seed && cp user-data meta-data seed/
hdiutil makehybrid -iso -joliet -default-volume-name cidata -o seed.iso seed
```

Then attach it as one more `-drive`, boot:

```bash
qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=./tank-os-disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=./edk2-arm-vars.fd \
  -drive file=./seed.iso,format=raw,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic
```

Requires `brew install qemu`. SSH once booted: `ssh -p 2222 openclaw@localhost`
using **your own key** from `seed.iso` above — drop the `-drive
file=./seed.iso,...` line entirely if you already know the published
image's baked-in key matches yours (e.g. you built it yourself).

**Don't swap `-nographic` for `-daemonize` to run headless.** `-accel hvf`
pulls in Apple's `Hypervisor.framework`, which starts Objective-C
runtime/GCD threads during QEMU's own init. `-daemonize` then `fork()`s to
detach — forking a process that already has live Objective-C runtime
threads is unsafe on modern macOS, and the runtime aborts immediately
(`objc[...]: ... may have been in progress in another thread when fork()
was called ... Crashing instead`). This is a QEMU+HVF/macOS limitation, not
anything image- or config-specific. Background the whole command at the
shell level instead, so the fork happens before HVF ever initializes:

```bash
nohup qemu-system-aarch64 \
  -M virt,highmem=on -accel hvf -cpu host -smp 2 -m 4096 \
  -drive file=./tank-os-disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=./edk2-arm-vars.fd \
  -drive file=./seed.iso,format=raw,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -display none -serial file:console.log \
  < /dev/null > qemu.log 2>&1 &
disown
```

**Expect several "Image ... start failed" / TPM / TRNG lines during boot —
these are benign.** EDK2/OVMF enumerates every PCI option ROM it finds and
tries to run each one regardless of architecture; `virtio-net-pci`'s
option ROM bundles a legacy x86 image alongside the EFI one, so EDK2 tries
the x86 image, logs `Image type X64 can't be loaded on AARCH64 UEFI
system`, and moves on to the correct image. The TPM/TRNG warnings likewise
just mean no vTPM/RNG device is attached, not that anything is broken.
None of this indicates a mismatched-architecture disk image — a genuinely
wrong-arch qcow2 wouldn't produce a working boot at all. If SSH succeeds
and `uname -a` inside the guest reports `aarch64`, the image is correct.

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
Fedora/RHEL ship by default:

```bash
virt-install \
  --connect qemu:///session \
  --name tank-os \
  --memory 4096 \
  --vcpus 2 \
  --disk ./tank-os-disk.qcow2,format=qcow2,bus=virtio \
  --import \
  --os-variant fedora-unknown \
  --network user,backend.type=passt,portForward0.proto=tcp,portForward0.range0.start=2222,portForward0.range0.to=22 \
  --graphics none \
  --console pty,target_type=serial \
  --cloud-init user-data=./user-data,meta-data=./meta-data \
  --noautoconsole
```

Verified on RHEL 10.2: `ssh -p 2222 openclaw@localhost` worked using a key
from `--cloud-init` that was never baked into the image, and `virsh
--connect qemu:///session console tank-os` attaches to the serial console.

Two things this fixes that the obvious version of this command gets wrong:

- **`--connect qemu:///session` instead of `sudo` + the default
  `qemu:///system`.** With `qemu:///system`, libvirt runs QEMU as the
  unprivileged system `qemu` user, which can't read a disk image anywhere
  under your home directory if it's mode `700` (RHEL's default) — you'd
  hit `Cannot access ... Permission denied` regardless of the disk's own
  file permissions, since the *directory* itself blocks traversal.
  `qemu:///session` runs QEMU as your own user instead, sidestepping the
  problem entirely — no `sudo`, no moving the disk into
  `/var/lib/libvirt/images/`.
- **`--network user,backend.type=passt,portForward0...` instead of
  `--network network=default`.** `network=default` is a system-level
  virtual network only available under `qemu:///system` — under
  `qemu:///session` there's no bridge to attach to, so it fails
  immediately. `backend.type=passt` (the `passt` package; usually
  preinstalled) plus explicit `portForward0.*` options gives usermode
  networking with host port forwarding, the session-mode equivalent of
  raw QEMU's `-netdev user,hostfwd=...`.

Or use the repo's portable QEMU script (`examples/boot-tank-os-qemu.sh`) the
same way `docs/build.md`'s "Launch on Linux (QEMU)" section describes, again
pointing it at `./tank-os-disk.qcow2` instead of a fresh
`out-tank-os/qcow2/disk.qcow2` — confirmed working as-is on RHEL 10.2,
auto-detecting both `/usr/libexec/qemu-kvm` (RHEL has no separate
`qemu-system-x86_64` binary) and `/usr/share/edk2/ovmf` (RHEL's OVMF path)
with no manual `QEMU_BIN`/`OVMF_CODE` overrides needed.

## Lima (macOS/Linux)

**Confirmed working** on Lima 2.2.0 / macOS (Apple Silicon, M3), 2026-07-28,
across all three of Lima's VM drivers. Ready-made manifests are at
`examples/lima/`:

| Manifest | Driver | Notes |
| --- | --- | --- |
| `tank-os-qemu.yaml` | QEMU | No `arch:` field — Lima defaults to the host's own architecture, and the containerdisk is a real multi-arch manifest, so this same config works unmodified on x86_64 Linux/macOS hosts too, not just Apple Silicon (only actually tested on aarch64 macOS so far — same HVF-equivalent acceleration path as the plain-QEMU recipe above) |
| `tank-os-vz.yaml` | Apple `Virtualization.framework` | macOS Apple Silicon only (untested on Intel Macs) — no firmware files to manage; networked over vsock instead of usermode NAT |
| `tank-os-krunkit.yaml` | krunkit (libkrun) | macOS Apple Silicon only (untested on Intel Macs) — keeps the whole stack on the same hypervisor family this repo's own Podman-machine build path already uses |

All three produced identical guest behavior (cloud-init, hostname,
OpenClaw/OpenShell bring-up) on the one configuration actually tested
(aarch64 macOS) — pick whichever driver is already installed; there's no
functional reason to prefer one over another for this image.

```bash
mkdir -p ~/.lima/_images
podman create --replace --name tank-os-extract quay.io/redhat-et/tank-os-containerdisk:latest
podman cp tank-os-extract:/disk/disk.qcow2 ~/.lima/_images/tank-os-disk.qcow2
podman rm tank-os-extract

limactl start --name tank-os ./examples/lima/tank-os-vz.yaml --tty=false
limactl shell tank-os
```

(Swap in `tank-os-qemu.yaml` or `tank-os-krunkit.yaml` for a different
driver. `tank-os-vz.yaml`/`tank-os-krunkit.yaml` also pin `arch: "aarch64"`
explicitly, since both are Apple-Silicon-only anyway; `tank-os-qemu.yaml`
leaves `arch` unset instead, since QEMU is the one driver here that's
genuinely portable across host architectures — see the table above.)

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

## Give OpenClaw a model provider key

The extracted image ships with no model provider configured — OpenClaw needs
at least one API key before it can respond to anything. As with the SSH key
above, you don't need an interactive shell on the VM for this: pipe the value
straight to `podman secret create` over SSH, using whichever `openclaw@<host>`
address the platform section above used to reach the VM (add `-p <port>` for
the QEMU/`virt-install` paths that forward a local port instead of exposing a
routable IP):

```bash
printf '%s' "$ANTHROPIC_API_KEY" | ssh openclaw@<host> "podman secret create anthropic_api_key -"
ssh openclaw@<host> "tank-openclaw-secrets && systemctl --user restart openclaw.service"
```

See [model-providers.md](model-providers.md) for the full list of supported
secret names, and
[provisioning.md](provisioning.md#injecting-secrets-from-the-host) for the
gateway-token equivalent and why this works without an interactive login
session.
