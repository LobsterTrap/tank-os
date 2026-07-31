# tank-os architecture: how it all fits together

This is a single reference for the full path from source repo to a running
agent sandbox — meant to orient a new user, admin, or contributor who's
looking at a running tank-os VM for the first time and wants the mental
model before diving into any one piece. Each section links to the doc that
covers its details in depth; this page focuses on how the pieces relate.

## The one-paragraph version

tank-os is a bootc container that builds into a bootable VM disk image.
Boot that VM, and it comes up running OpenClaw (an AI coding agent gateway)
inside one Podman container, talking to an OpenShell-managed sandbox
container for isolated command execution, on top of a rootless-Podman host
managed by systemd user services. Three layers of isolation stack on top
of each other: the hypervisor isolates the VM from its host, OpenShell's
sandbox isolates agent tool-calls from the rest of the VM, and OpenShell's
network policy isolates what each sandboxed binary can reach on the
network.

## Part 1 — From source to running VM

```
tank-os repo (bootc/Containerfile)
        │  make build
        ▼
quay.io/redhat-et/tank-os:latest          <- the bootc OS image
        │  make build-qcow2
        ▼
disk.qcow2                                 <- a bootable VM disk
        │  wrapped FROM scratch (deploy/containerdisk/Containerfile)
        ▼
quay.io/redhat-et/tank-os-containerdisk:latest   <- OCI image carrying the disk
        │
        ├──► macOS: extract qcow2, convert to raw, run with vfkit
        ├──► Linux/macOS: extract qcow2, run with QEMU (+HVF on macOS)
        └──► OpenShift Virtualization: containerdisk referenced directly
             by a KubeVirt DataVolume/VM manifest — no manual extraction
```

Both published images (`tank-os` and `tank-os-containerdisk`) are
multi-arch manifest lists (aarch64 + x86_64) and public-read.

| Where you're running | Doc |
|---|---|
| Build the bootc image and qcow2 locally | `docs/build.md` |
| Pull pre-built images and boot on macOS/Linux (vfkit, QEMU, Lima) | `docs/quickstart-prebuilt.md` |
| Boot on OpenShift Virtualization (per-user provisioning, containerdisk publishing) | `docs/openshift-virtualization.md` |
| Cloud-init config, EC2, libvirt, editing OpenClaw config pre-boot | `docs/provisioning.md` |

A second image, `quay.io/redhat-et/tank-claw-openshell`, is built
separately (`bootc/openclaw-openshell/Containerfile`) — it's not the VM's
OS image, it's the OpenClaw gateway container image *baked into* that VM
(see Part 3).

## Part 2 — What's actually running once the VM is up

SSH into a booted VM as `openclaw` and `podman ps` shows three containers.
Two are the focus of this doc; `service-gator` is a separate MCP server
covered in `docs/service-gator.md` and not discussed further here.

| Container | Image | Role |
|---|---|---|
| `openclaw` | `quay.io/redhat-et/tank-claw-openshell:<pinned>` | The OpenClaw gateway — runs the agent loop, decides what commands to execute |
| `openshell-default--tankos-openclaw-*` | `ghcr.io/lobstertrap/openshell-hummingbird-images/sandboxes/openclaw@sha256:...` | The sandbox — where OpenClaw's tool-call commands actually execute, isolated |
| `service-gator` | `ghcr.io/cgwalters/service-gator` | MCP server for scoped external-service access (GitHub/GitLab/JIRA) — see `docs/service-gator.md` |

Neither `openclaw` nor the sandbox container is started by `podman run`
directly — both come up through systemd:

- **`openclaw.container`** is a Podman Quadlet unit, started as a
  `systemctl --user start openclaw.service` under the `openclaw` user
  (currently *not* auto-started on first boot — a known gap, see
  `docs/quickstart-prebuilt.md`'s manual-start step).
- **The sandbox** is pre-created by an `ExecStartPre=` script
  (`bootstrap-openshell-sandbox`) that runs *before* `openclaw.container`
  itself starts — so by the time OpenClaw's gateway comes up, the sandbox
  it needs already exists.
- **`openshell-gateway.service`** is a separate rootless systemd *user*
  service, running directly on the VM host (not in a container). It's
  installed via RPM (`bootc/Containerfile`), not built by this repo. This
  is the process with real Podman access — it's what actually creates and
  manages sandbox containers.

## Part 3 — OpenClaw and OpenShell: three components, one job

The mental model that took the most untangling in this project: **OpenClaw
never directly creates or manages the sandbox.** Three distinct pieces
divide that responsibility:

| Component | Where it runs | What it does |
|---|---|---|
| `openshell-gateway` | VM host, rootless systemd user service | The only piece with real Podman access. Creates/manages sandbox containers on request. |
| `openshell` CLI | Inside the `openclaw` container | A thin client. OpenClaw's `openshell` plugin shells out to this CLI (`sandbox get`/`ssh-config`), which talks to `openshell-gateway` over the VM's loopback interface. |
| The sandbox container | Standalone Podman container, pre-created | Where OpenClaw's tool-call commands actually execute, reached via SSH. |

Two consequences fall out of this split:

1. **`openclaw.container` runs with `Network=host`.** The CLI inside it
   needs to reach `openshell-gateway` at `https://127.0.0.1:17670` — a
   container's normal network namespace can't see the host's loopback
   without an explicit port mapping, and the gateway only binds to
   loopback. This does widen what the OpenClaw container can reach
   compared to the isolated-network default, but it's the gateway's own
   control-plane traffic that's exposed, not the sandboxed tool-call path
   OpenShell exists to contain. (`docs/openshell.md` covers the trade-off
   and a lower-exposure alternative worth revisiting.)
2. **Sandbox selection is static, by design.** OpenClaw's plugin config
   (`plugins.entries.openshell.config.from: "tankos-openclaw"`) references
   a sandbox by name, not by image. That's because OpenShell's `from`
   field only accepts a short community-sandbox name upstream (e.g.
   `openshell sandbox create --from base`) — it can't express tank-os's
   full, digest-pinned custom image reference. The workaround:
   `bootstrap-openshell-sandbox` pre-creates exactly one sandbox under a
   fixed name before the gateway starts; OpenClaw's plugin only ever does
   `sandbox get`, never `sandbox create`. There is currently no mechanism
   for multiple sandbox flavors per deployment — see
   `docs/dev/sandbox-image-content.md` for open questions on this.

### First-boot sequence

`openclaw.container` runs two `ExecStartPre=` scripts, in order, both
idempotent (safe to re-run every boot):

1. `bootstrap-openclaw` — writes `openclaw.json` (sandbox backend config,
   gateway token) on first run only.
2. `bootstrap-openshell-sandbox` — installs the `openshell` plugin into the
   persisted config volume, waits for `openshell-gateway.service` to be
   active, and pre-creates the sandbox if it doesn't exist yet.

First boot pulls both the OpenClaw+OpenShell image and the sandbox image
(a few hundred MB combined), which is why the Quadlet's
`TimeoutStartSec` is generously set (900s) — a known slow-first-boot
pattern also documented for image pulls in `docs/provisioning.md`.

## Part 4 — Isolation layers, stacked

Three independent boundaries apply to any command an agent runs, from
outermost to innermost:

1. **The VM itself** — hypervisor-level isolation (vfkit/QEMU/KubeVirt)
   between the tank-os guest and its host.
2. **The OpenShell sandbox** — a separate Podman container the agent's
   commands execute inside, with its own filesystem policy (only specific
   paths writable), process policy (unprivileged `sandbox` user), and
   seccomp/Landlock restrictions. The gateway container (`openclaw`) never
   executes agent commands directly — it only ever asks the sandbox to.
3. **OpenShell's network policy** — inside the sandbox, network egress is
   default-deny, enforced per `(binary, endpoint)` pair via
   `/proc/{pid}/exe` inode resolution and SHA256 trust-on-first-use
   binary identity, not just a host allowlist. A binary with no matching
   policy entry can exist but can't reach the network at all.

What's actually installed in the sandbox image, and what policy entries
back those tools, is an open design question at time of writing — see
`docs/dev/sandbox-image-content.md`, which also covers a known-unverified
gap in the network-policy layer under rootless Podman
(`CAP_SYS_PTRACE`, tracked in `docs/openshell.md`).

## Glossary

| Term | Meaning |
|---|---|
| bootc | A bootable OS built and shipped as an OCI container image |
| containerdisk | KubeVirt's convention: a `FROM scratch` OCI image whose only content is a VM disk file, so a registry can distribute disk images the same way it distributes containers |
| Quadlet | Podman's systemd-unit-generator format (`*.container` files) for running containers as managed services |
| OpenShell gateway | The host-side daemon with real Podman access; creates and manages sandboxes |
| OpenShell supervisor | The in-sandbox process (root, briefly) that drops privileges and enforces filesystem/process/network policy before the agent's command runs |
| Hummingbird | Red Hat's project producing minimal, frequently-patched base images (productized as Red Hat Hardened Images); the sandbox image's OS base |

## Where to go deeper

- `docs/build.md` — building the bootc image and qcow2 locally
- `docs/quickstart-prebuilt.md` — running pre-built images on macOS/Linux
- `docs/openshift-virtualization.md` — per-user provisioning on OpenShift Virtualization
- `docs/provisioning.md` — cloud-init, EC2, libvirt, editing OpenClaw config
- `docs/openshell.md` — OpenShell sandboxing architecture in full detail
- `docs/service-gator.md` — the third container, scoped external-service access
- `docs/model-providers.md` — API keys and inference provider configuration
- `docs/cli.md` — the OpenClaw CLI and dashboard
- `docs/dev/sandbox-image-content.md` — open discussion on sandbox image scope and content
