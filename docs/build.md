# Build

## Build The Bootc Container Image

Skip this section if you want to build a disk image directly from the published
image:

```text
quay.io/sallyom/tank-os:latest
```

That image is published for both `arm64` and `amd64`, so Podman Desktop or
bootc-image-builder can select the right architecture for your target.

Build the bootc image from the repo root. In these commands, the final `bootc`
argument is the build context directory in this repo:

```text
tank-os/
├── bootc/
│   ├── Containerfile
│   └── rootfs/
└── docs/
```

For Apple Silicon:

```bash
podman build \
  --platform linux/arm64 \
  -t localhost/tank-os:latest \
  -f bootc/Containerfile \
  bootc
```

For x86_64:

```bash
podman build \
  --platform linux/amd64 \
  -t localhost/tank-os:latest \
  -f bootc/Containerfile \
  bootc
```

The default base is `quay.io/fedora/fedora-bootc:latest`. For a pinned build:

```bash
podman build \
  --build-arg FEDORA_BOOTC_BASE=quay.io/fedora/fedora-bootc:<tag> \
  -t localhost/tank-os:<tag> \
  -f bootc/Containerfile bootc
```

## Build A Disk Image With Podman Desktop

The Podman Desktop BootC extension can build a VM disk image from
`localhost/tank-os:latest` or the published `quay.io/sallyom/tank-os:latest`.

Recommended local test settings on Apple Silicon:

- Bootc image: `localhost/tank-os:latest`
- Or published image: `quay.io/sallyom/tank-os:latest`
- Disk image type: `qcow2`
- Target architecture: `arm64` or `aarch64`
- Root filesystem: `xfs`
- Output folder: a dedicated writable directory such as `/Users/<you>/git/out-tank-os`
- User: `openclaw`
- SSH public key: your Mac SSH public key
- Groups: `wheel`
- Password: leave empty

The output should be:

```text
<output-folder>/qcow2/disk.qcow2
```

See:

- Podman Desktop BootC extension: https://github.com/podman-desktop/extension-bootc
- bootc-image-builder docs: https://osbuild.org/docs/bootc/
- bootc docs: https://bootc-dev.github.io/bootc/

## Build A Disk Image Manually

Create an output directory:

```bash
mkdir -p out-tank-os
```

Optionally create a bootc-image-builder config to inject a local SSH key. This
is convenient for local VM tests. Do not put private keys or long-lived secrets
here.

See [examples/bootc-config.json](../examples/bootc-config.json) for a complete template.
Copy and customize it:

```bash
cp examples/bootc-config.json out-tank-os/config.json
# Edit with your SSH public key:
sed -i 's/REPLACE_WITH_YOUR_PUBLIC_KEY/ssh-ed25519 AAAA.../' out-tank-os/config.json
```

Or create inline:

```bash
cat > out-tank-os/config.json <<'EOF'
{
  "customizations": {
    "user": [
      {
        "name": "openclaw",
        "key": "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-os",
        "groups": ["wheel"]
      }
    ]
  }
}
EOF
```

Build the QCOW2 with bootc-image-builder. On macOS with Podman Desktop, use the
rootful Podman machine connection because bootc-image-builder needs privileged
access to the container storage.

```bash
podman --connection podman-machine-default-root run \
  --rm \
  --name tank-os-bootc-image-builder \
  --tty \
  --privileged \
  --security-opt label=type:unconfined_t \
  -v "$PWD/out-tank-os:/output/" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/out-tank-os/config.json:/config.json:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  localhost/tank-os:latest \
  --output /output/ \
  --local \
  --progress verbose \
  --type qcow2 \
  --target-arch arm64 \
  --rootfs xfs
```

For x86_64 output, use:

```bash
--target-arch amd64
```

The resulting disk image is:

```text
out-tank-os/qcow2/disk.qcow2
```

## What The Image Installs

The image creates an `openclaw` login user with UID/GID 1000, enables linger for that user, and installs a rootless Quadlet at:

```text
/etc/containers/systemd/users/1000/openclaw.container
```

On boot, OpenClaw state lives at:

```text
/var/home/openclaw/.openclaw
```

When logged in as `openclaw`, that is `~/.openclaw`.

## Launch on Linux (QEMU)

Use the provided launch script for portable QEMU invocation with automatic KVM 
detection and TCG fallback:

```bash
chmod +x examples/boot-tank-os-qemu.sh
./examples/boot-tank-os-qemu.sh out-tank-os
```

The script:

- Detects KVM availability and falls back to TCG if unavailable
- Auto-locates OVMF firmware files (`/usr/share/OVMF/`, `/usr/share/ovmf/`, etc.)
- Prepares OVMF variables for write access
- Forwards SSH port to localhost:2222

**Manual QEMU invocation** (if you prefer):

```bash
# Check for /dev/kvm; if unavailable, use accel=tcg
ACCEL="kvm"
[[ -e /dev/kvm ]] || ACCEL="tcg"

qemu-system-x86_64 \
  -machine q35,accel="$ACCEL" \
  -cpu max \
  -smp 2 \
  -m 4096 \
  -drive file=out-tank-os/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=out-tank-os/qcow2/OVMF_VARS_4M.fd \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic
```

**Note**: OVMF paths vary by distribution. Common locations:
- `/usr/share/OVMF/OVMF_CODE_4M.fd` (Red Hat, Fedora, openSUSE)
- `/usr/share/ovmf/OVMF.fd` (Debian, Ubuntu)
- `/usr/share/edk2-ovmf/OVMF_CODE.fd` (Arch)

The `_4M` variant is preferred for modern systems; fall back to standard paths if unavailable.

## Upgrade A Running VM

After pushing a new bootc image, switch the VM to the registry ref:

```bash
sudo bootc status
sudo bootc switch --apply quay.io/sallyom/tank-os:latest
```

After the reboot, future updates against the same tracked tag can use:

```bash
sudo bootc upgrade --apply
```
