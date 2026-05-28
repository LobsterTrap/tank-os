# Build

## Quick Start with Makefile

The easiest way to build locally is using `make`:

```bash
# Build the image (auto-detects architecture)
make build

# View all available targets
make help
```

See **Makefile Targets** below for details.

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

## Makefile Targets

The `Makefile` provides convenient local build commands:

```bash
# Build the image locally (auto-detects architecture)
make build

# Build and push to a registry (requires IMAGE_REGISTRY and IMAGE_NAMESPACE)
make build push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg

# Build a QCOW2 disk image (requires config.toml in repo root)
make build-qcow2

# Build an ISO installer (requires config.toml in repo root)
make build-iso

# Verify image signature (if COSIGN_PUBLIC_KEY env var is set)
make verify COSIGN_PUBLIC_KEY="$(cat cosign.pub)" \
  IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg

# Clean build artifacts
make clean
```

The Makefile automatically detects your architecture (`arm64` or `amd64`) and builds for that platform. Images are tagged as `localhost/tank-os:latest` by default, or `<REGISTRY>/<NAMESPACE>/tank-os:latest` if registry variables are set.

**Note**: The Makefile uses `IMAGE_NAMESPACE` for the image path. Authentication credentials are handled separately via `podman login` before running `make push`.

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
