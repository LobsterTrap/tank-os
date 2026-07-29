# Build

## Quick Start

The local build commands are exposed through the repo `Makefile`:

```bash
# Build the bootc container image for your local architecture
make build

# View all available targets and the active image configuration
make help
```

## Build The Bootc Container Image

Skip this section if you want to build a disk image directly from the published
image:

```text
quay.io/redhat-et/tank-os:latest
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
make build ARCH=arm64
```

For x86_64:

```bash
make build ARCH=amd64
```

The default base is `quay.io/fedora/fedora-bootc:latest`. For a pinned build:

```bash
make build FEDORA_BOOTC_BASE=quay.io/fedora/fedora-bootc:<tag>
```

## Build A Disk Image With Podman Desktop

The Podman Desktop BootC extension can build a VM disk image from
`localhost/tank-os:latest` or the published `quay.io/redhat-et/tank-os:latest`.

Recommended local test settings on Apple Silicon:

- Bootc image: `localhost/tank-os:latest`
- Or published image: `quay.io/redhat-et/tank-os:latest`
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

## Build A Disk Image With Make

Create a bootc-image-builder config in the repo root. This is convenient for
local VM tests. Do not put private keys or long-lived secrets here.

```bash
cp examples/bootc-config.toml config.toml
$EDITOR config.toml
```

Or create it inline:

```bash
cat > config.toml <<'EOF'
[[customizations.user]]
name = "openclaw"
key = "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-os"
groups = ["wheel"]
EOF
```

Build the QCOW2 image:

```bash
make build-qcow2
```

Build an installer ISO:

```bash
make build-iso
```

For x86_64 output, use:

```bash
make build-qcow2 ARCH=amd64
```

The resulting disk image is:

```text
out-tank-os/qcow2/disk.qcow2
```

On macOS with Podman Desktop, use the rootful Podman machine connection because
bootc-image-builder needs privileged access to the container storage.

**On a bare Linux host (RHEL, Fedora Workstation/Server, etc. — no Podman
Desktop/machine layer)**: `build-qcow2`'s `--local` flag and its
`-v /var/lib/containers/storage:/var/lib/containers/storage` bind-mount both
require *rootful* Podman, and `--privileged` alone doesn't make a rootless
invocation rootful — bootc-image-builder checks that the outer `podman`
command itself is rootful, not just that the container it launches runs
privileged. If you built the image as your own user (the Makefile's default,
rootless Podman), `sudo make build-qcow2` alone will still fail to find it:
rootless and rootful Podman keep entirely separate image storage
(`sudo podman images` and `podman images` show different lists on the same
host). Build and run both steps as root instead:

```bash
sudo make build
sudo make build-qcow2
```

## Makefile Targets

Common targets:

```bash
# Build the image locally
make build

# Build and push to a registry
make build push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg

# Build disk images using config.toml
make build-qcow2
make build-iso

# Verify a signed registry image
make verify COSIGN_PUBLIC_KEY="$(cat cosign.pub)" \
  IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg

# Remove build artifacts
make clean
```

Images are tagged as `localhost/tank-os:latest` by default, or
`<REGISTRY>/<NAMESPACE>/tank-os:latest` when `IMAGE_REGISTRY` and
`IMAGE_NAMESPACE` are set. Authentication credentials are handled separately
with `podman login` before `make push`.

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

Build an x86_64 QCOW2 first:

```bash
make build-qcow2 ARCH=amd64
```

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

You can override the defaults with `QEMU_BIN`, `OVMF_CODE`, `OVMF_VARS`,
`SSH_PORT`, `QEMU_MEM`, and `QEMU_SMP`.

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

**Exiting `-nographic`**: this attaches the VM's serial console directly to
your terminal, which is what's showing the login prompt — it isn't hung, it's
working as intended. QEMU's own escape sequence (not SSH's `~.`, which only
applies inside an actual SSH session) is `Ctrl-A` followed by a command key:

- `Ctrl-A x` — quit QEMU
- `Ctrl-A c` — toggle between the serial console and the QEMU monitor
- `Ctrl-A h` — list all escape commands

If you don't need the console at all (e.g. you're only going to SSH in via
the forwarded port), see "Run without attaching a console" below instead of
using `-nographic`.

**Note**: OVMF paths vary by distribution. Common locations:
- `/usr/share/OVMF/OVMF_CODE_4M.fd` or `/usr/share/OVMF/OVMF_CODE.fd` (Red Hat, Fedora, openSUSE, Debian, Ubuntu)
- `/usr/share/ovmf/OVMF_CODE_4M.fd` or `/usr/share/ovmf/OVMF_CODE.fd` (Debian, Ubuntu)
- `/usr/share/edk2-ovmf/OVMF_CODE.fd` (Arch)

The `_4M` variant is preferred for modern systems; fall back to standard paths if unavailable.

**RHEL note**: RHEL's `/usr/share/OVMF/` only ships `OVMF_CODE.secboot.fd`
(no plain `OVMF_CODE.fd`), so the auto-detection above won't find it. The
plain firmware lives at `/usr/share/edk2/ovmf/` instead — pass it
explicitly: `OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd`.

## Launch on macOS (Apple Silicon, QEMU + HVF)

`examples/boot-tank-os-qemu.sh` doesn't support aarch64 (it hardcodes
`qemu-system-x86_64` and `-machine q35`, an x86-only machine type) or
Homebrew's firmware layout, so build an `arm64` disk and invoke QEMU
directly instead:

```bash
make build-qcow2 ARCH=arm64
qemu-img resize out-tank-os/qcow2/disk.qcow2 20G

qemu_share="$(brew --prefix qemu)/share/qemu"
cp "$qemu_share/edk2-arm-vars.fd" out-tank-os/qcow2/edk2-arm-vars.fd

qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=out-tank-os/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=out-tank-os/qcow2/edk2-arm-vars.fd \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic
```

Notes:

- `-accel hvf -cpu host` gives hardware acceleration on Apple Silicon
  (there's no `/dev/kvm` on macOS, so the `tcg`-fallback logic in
  `boot-tank-os-qemu.sh` isn't relevant here).
- The AArch64 UEFI code pairs with the generic `edk2-arm-vars.fd`
  variables file — there's no separate `edk2-aarch64-vars.fd`.
- `make build-qcow2` on macOS needs a **rootful** Podman machine
  (`podman machine inspect --format '{{.Rootful}}'` should say `true`) —
  do **not** prefix the command with `sudo` on the host shell, that
  breaks the connection to your own Podman machine instead of granting
  privilege. If `podman machine` isn't already rootful, recreate it or
  run `podman machine set --rootful` (may require a machine restart).

### Run without attaching a console

If you only need SSH access (via the forwarded port) and don't want QEMU to
take over your terminal, replace `-nographic` with `-display none` plus
`-daemonize` — QEMU detaches into the background immediately instead of
attaching the serial console to your shell:

```bash
qemu-system-aarch64 \
  -M virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=out-tank-os/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=out-tank-os/qcow2/edk2-arm-vars.fd \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -display none \
  -serial file:out-tank-os/qcow2/console.log \
  -daemonize \
  -pidfile out-tank-os/qcow2/qemu.pid
```

Your prompt returns right away, but the VM itself still takes a few seconds
to boot — SSH won't be up yet. Check whether it's reached the login prompt
before trying to connect:

```bash
grep "login:" out-tank-os/qcow2/console.log
```

No output means it's still booting; re-run the `grep` (or poll it:
`until grep -q "login:" out-tank-os/qcow2/console.log 2>/dev/null; do sleep 1; done`)
until it matches, then:

```bash
ssh -p 2222 openclaw@localhost
tail -f out-tank-os/qcow2/console.log   # if you need to watch boot progress
kill "$(cat out-tank-os/qcow2/qemu.pid)"   # to shut the VM down
```

(This same `-display none -daemonize -serial file:... -pidfile ...`
substitution works on the Linux invocation above too — it isn't
aarch64/macOS-specific, just documented here since it's what came up while
testing this section.)

## Upgrade A Running VM

After pushing a new bootc image, switch the VM to the registry ref:

```bash
sudo bootc status
sudo bootc switch --apply quay.io/redhat-et/tank-os:latest
```

After the reboot, future updates against the same tracked tag can use:

```bash
sudo bootc upgrade --apply
```

## CI/CD System

The repository includes a full GitHub Actions CI/CD pipeline adapted from enterprise bootc image build patterns.

### Workflows

1. **PR validation** (`.github/workflows/pr.yaml`)
   - Triggers on pull requests to `main`
   - Builds images for both `amd64` and `arm64` architectures
   - Validates images with `buildah inspect`
   - No images are pushed

2. **Semantic release** (`.github/workflows/create-release.yml`)
   - Triggers on push to `main` (merged PRs)
   - Validates the build on both architectures
   - Creates a semantic version tag (e.g., `v1.2.3`) using `python-semantic-release`

3. **Full release** (`.github/workflows/build-release.yml`)
   - Triggers on version tags (`v*`)
   - Builds per-architecture images and pushes them by digest
   - Creates multi-arch manifest lists with tags: `latest`, `<VERSION>`, `<SHA>`
   - **Conditionally** signs images with cosign (if `COSIGN_PRIVATE_KEY` secret is set)
   - Generates SBOM (Software Bill of Materials)
   - Creates build provenance and SBOM attestations
   - Runs Trivy vulnerability scanner and uploads results to GitHub Security

4. **PR title linting** (`.github/workflows/commitlint.yml`)
   - Validates PR titles follow conventional commit format

5. **OpenSSF Scorecard** (`.github/workflows/scorecard.yml`)
   - Weekly security analysis via OpenSSF Scorecard

### Fork Setup: Required Configuration

To use the CI/CD system in a fork, configure these **repository variables** (Settings → Secrets and variables → Actions → Variables):

- `IMAGE_REGISTRY` — registry hostname (e.g., `quay.io` or `ghcr.io`) **[required]**
- `IMAGE_NAMESPACE` — organization or user namespace in the registry (e.g., `myorg` or `myuser`) **[required]**
  - This is the path component after the registry: `quay.io/{IMAGE_NAMESPACE}/tank-os`
  - Examples: `myorg`, `myuser`, `my-team`

And these **repository secrets** (Settings → Secrets and variables → Actions → Secrets):

- `REGISTRY_USER` — username for authentication to the registry **[required]**
  - This is used for `podman login` / `docker login` authentication only
  - May be different from `IMAGE_NAMESPACE` (e.g., robot account or service account)
- `REGISTRY_PASSWORD` — registry password or token **[required]**
- `FG_PAT` — fine-grained GitHub Personal Access Token for creating release tags **[required]**
  - Token needs `contents: write` permission on the repository
  - Create at: https://github.com/settings/personal-access-tokens/new

**Example Configuration**:
- **Scenario 1**: Personal account pushing to personal namespace
  - `IMAGE_REGISTRY`: `quay.io`
  - `IMAGE_NAMESPACE`: `myuser`
  - `REGISTRY_USER`: `myuser` (secret)
  - `REGISTRY_PASSWORD`: `mypassword` (secret)
  - **Result**: Images pushed to `quay.io/myuser/tank-os`

- **Scenario 2**: Robot account pushing to organization namespace
  - `IMAGE_REGISTRY`: `quay.io`
  - `IMAGE_NAMESPACE`: `myorg`
  - `REGISTRY_USER`: `myorg+robot` (secret)
  - `REGISTRY_PASSWORD`: `robot-token` (secret)
  - **Result**: Images pushed to `quay.io/myorg/tank-os`

- **Scenario 3**: GitHub GHCR with personal account pushing to org
  - `IMAGE_REGISTRY`: `ghcr.io`
  - `IMAGE_NAMESPACE`: `myorg`
  - `REGISTRY_USER`: `myuser` (secret)
  - `REGISTRY_PASSWORD`: `ghp_...` (secret - GitHub PAT)
  - **Result**: Images pushed to `ghcr.io/myorg/tank-os`

### Fork Setup: Optional Configuration (Image Signing)

To enable image signing with cosign:

**Repository variables:**
- `COSIGN_PUBLIC_KEY` — cosign public key content (PEM format, multi-line)
  - Paste the entire content of `cosign.pub` directly into the variable
  - Include the `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----` lines
  - GitHub variables handle multi-line content correctly

**Repository secrets:**
- `COSIGN_PRIVATE_KEY` — cosign private key (full PEM content)
- `COSIGN_PASSWORD` — passphrase for the cosign key

If these are not set, the signing steps are gracefully skipped. Generate a cosign keypair:

```bash
cosign generate-key-pair
# Then copy the contents of cosign.pub (entire file) to COSIGN_PUBLIC_KEY variable
# And copy the contents of cosign.key (entire file) to COSIGN_PRIVATE_KEY secret
```

**Security Note**: The CI/CD pipeline includes automatic cleanup of signing keys:
- A dedicated cleanup step always runs (even if signing fails) to remove temporary key files
- Cosign cache directories (`~/.sigstore`, `~/.cosign`) are purged after signing
- The Makefile's `verify` target uses a trap to ensure public key cleanup on exit
- Private keys are never written to disk (passed via environment variables only)

### Optional: Release Registry Pinning

Set the `RELEASE_REGISTRY` variable to the full registry/repo path that deployed images should trust for updates:

- `RELEASE_REGISTRY` — e.g., `quay.io/myorg/tank-os`

This is used for container signature policy configuration if you implement supply chain verification.

### First-time Setup

After setting the required variables and secrets:

1. Merge a PR to `main` → triggers `create-release.yml` which creates the first tag (e.g., `v0.1.0`)
2. Tag push triggers `build-release.yml` → multi-arch image is built, signed (if configured), and pushed to your registry

### Semantic Versioning

The pipeline uses `python-semantic-release` to automatically determine version bumps based on commit messages:

- `feat:` prefix → minor version bump (e.g., `v1.2.0` → `v1.3.0`)
- `fix:` prefix → patch version bump (e.g., `v1.2.0` → `v1.2.1`)
- `BREAKING CHANGE:` in commit body → major version bump (e.g., `v1.2.0` → `v2.0.0`)

PR titles are validated to follow conventional commit format via commitlint.

### Dependabot

The repository includes Dependabot configuration (`.github/dependabot.yml`) for automated updates:
- GitHub Actions (weekly)
- Docker base images (weekly)
