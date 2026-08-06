# tank-os architecture: how it all fits together

This is a single reference for the full path from source repo to a running
agent sandbox — meant to orient a new user, admin, or contributor who's
looking at a running tank-os VM for the first time and wants the mental
model before diving into any one piece. Each section links to the doc that
covers its details in depth; this page focuses on how the pieces relate.

## The one-paragraph version

tank-os is a bootc container that builds into a bootable VM disk image.
Boot that VM, and it comes up running
[redhat-et/openclaw-csb](https://github.com/redhat-et/openclaw-csb)'s
("CSB," the Corporate Standard Build) own published image inside a single
OpenShell sandbox — CSB's own entrypoint runs OpenClaw (an AI coding agent
gateway) directly inside that sandbox, and OpenClaw's tool calls execute as
ordinary child processes in that same sandbox, all on top of a
rootless-Podman host managed by systemd user services. Two layers of
isolation stack on top of each other: the hypervisor isolates the VM from
its host, and OpenShell's sandbox isolates the entire OpenClaw-plus-tool-call
workload from the rest of the VM, with its own default-deny network policy
controlling what each sandboxed binary can reach.

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

tank-os itself builds and publishes only the two images above. The actual
OpenClaw+OpenShell integration is a separate, external image tank-os
doesn't build: CSB's own `quay.io/redhat-et/openclaw:csb-<tag>` (pinned via
the `CSB_IMAGE_TAG` build arg in `bootc/Containerfile`/`Makefile`),
consumed as-is and run as the VM's OpenShell sandbox workload (see Part 3).

## Part 2 — What's actually running once the VM is up

SSH into a booted VM as `openclaw` and `podman ps` shows two containers.

| Container | Image | Role |
|---|---|---|
| `openshell-default--tank-csb-*` | `quay.io/redhat-et/openclaw:csb-<tag>` | Runs OpenClaw itself (CSB's own entrypoint and gateway process) plus everything OpenClaw's tool calls execute — the one-sandbox model. Isolated by OpenShell's filesystem/network/process policy. |
| `service-gator` | `ghcr.io/cgwalters/service-gator` | MCP server for scoped external-service access (GitHub/GitLab/JIRA) — see `docs/service-gator.md`. A retirement candidate for GitHub/Forgejo now that OpenShell providers cover the same need natively (see `docs/dev/csb-bootc-deployment-design.md` Findings I/J). |

Neither container is started by `podman run` directly — both come up
through systemd:

- **The `tank-csb` sandbox** is created by `openshell sandbox create`,
  invoked from `/usr/libexec/tank-os/bootstrap-csb-sandbox` — the
  `ExecStart` of `openclaw.service`, a plain systemd `--user` oneshot unit
  (not a Podman Quadlet; CSB's image runs via `openshell sandbox create`,
  never `podman run`). It's deleted and recreated fresh on every start of
  that unit, not resumed. Ongoing supervision comes from a separate
  `openclaw-healthcheck.timer`, not from systemd tracking the `sandbox
  create` process itself — see `docs/openshell.md` for why.
- **`openshell-gateway.service`** is a separate rootless systemd *user*
  service, running directly on the VM host (not in a container). It's
  installed via RPM (`bootc/Containerfile`), not built by this repo. This
  is the process with real Podman access — it's what actually creates and
  manages sandbox containers, including `tank-csb`.

## Part 3 — OpenClaw and OpenShell: one sandbox, not two

Earlier tank-os designs ran OpenClaw unsandboxed, reaching a *separate*
OpenShell sandbox over SSH for each tool call. That's gone: **OpenClaw now
runs directly inside the same OpenShell sandbox its tool calls execute
in** — CSB's own image and entrypoint, with no
`agents.defaults.sandbox`/`openshell` plugin configuration in OpenClaw at
all (see `docs/dev/csb-bootc-deployment-design.md` Finding C, the
"one-sandbox model"). Three pieces still divide the work, but the split
looks different from before:

| Component | Where it runs | What it does |
|---|---|---|
| `openshell-gateway` | VM host, rootless systemd user service | The only piece with real Podman access. Creates/manages sandbox containers, including `tank-csb`, on request. |
| `openshell` CLI | Directly on the VM host, as the `openclaw` user (no container involved) | Invoked by `bootstrap-csb-sandbox` to register OpenShell providers, stage non-provider secrets, and create/poll `tank-csb`. |
| `tank-csb` sandbox | Standalone Podman container, deleted and recreated on every start | Runs CSB's own `openclaw gateway` process directly, plus everything OpenClaw's tool calls execute — both constrained by the same sandbox policy, reached via `openshell sandbox exec`/`forward`, not SSH into a second sandbox. |

One consequence of this shape: **sandbox creation is static, by design,
but for a different reason than before.** `bootstrap-csb-sandbox` deletes
and recreates exactly one sandbox, always named `tank-csb`, on every start
of `openclaw.service` — there's no OpenClaw-side
`plugins.entries.openshell.config.from` indirection to work around
anymore, since CSB configures no `openshell` plugin at all; it's just a
fixed `--name tank-csb` argument passed straight to `openshell sandbox
create`. There is currently no mechanism for multiple sandbox flavors per
deployment — see `docs/dev/sandbox-image-content.md` for open questions on
this.

### Every-start sequence

`openclaw.service` runs `bootstrap-csb-sandbox` as its `ExecStart` on
*every* start, not just first boot (a oneshot, not a long-running
process): it provisions the gateway-token Podman secret if missing,
registers OpenShell providers and stages other secrets tank-os has Podman
secrets for, then deletes any leftover `tank-csb` and recreates it fresh,
polling until `Ready`. A separate `openclaw-healthcheck.timer` restarts
`openclaw.service` if the gateway stops responding — see
`docs/openshell.md` for the full sequence and Finding L (the `sandbox
create` CLI's foreground attachment isn't the supervised workload; the
health-check timer is what actually provides ongoing supervision).

First start pulls CSB's image and creates the sandbox, which is why
`openclaw.service`'s `TimeoutStartSec` is generously set (900s) — a known
slow-first-boot pattern also documented for image pulls in
`docs/provisioning.md`. Both `openclaw.service` and
`openclaw-healthcheck.timer` are enabled at build time, so this all runs
unattended from first boot with no manual start step.

## Part 4 — Isolation layers, stacked

Two independent boundaries apply to any command an agent runs (down from
three in earlier designs, since OpenClaw's own process is no longer
outside the sandbox boundary):

1. **The VM itself** — hypervisor-level isolation (vfkit/QEMU/KubeVirt)
   between the tank-os guest and its host.
2. **The `tank-csb` OpenShell sandbox** — a single Podman container that
   OpenClaw itself, and everything its tool calls execute, run inside,
   with its own filesystem policy (only specific paths writable), process
   policy (unprivileged `sandbox` user), and seccomp/Landlock
   restrictions. Within that same boundary, OpenShell's network policy
   enforces default-deny egress per `(binary, endpoint)` pair, verified
   via `/proc/{pid}/exe` inode resolution and SHA256 trust-on-first-use
   binary identity — a binary with no matching policy entry can exist but
   can't reach the network at all. This now covers OpenClaw's own
   outbound LLM-provider traffic (via OpenShell `provider`s) in addition
   to tool-call traffic, since both run inside the same sandbox.

What's actually installed in CSB's sandbox image, and what policy entries
back those tools, is owned by CSB upstream, not tank-os — see
`docs/dev/sandbox-image-content.md` for the (partly historical) discussion
of sandbox image content, and `docs/openshell.md`'s "Known limitation"
section for a gap in the network-policy layer under rootless Podman
(`CAP_SYS_PTRACE`).

## Glossary

| Term | Meaning |
|---|---|
| bootc | A bootable OS built and shipped as an OCI container image |
| containerdisk | KubeVirt's convention: a `FROM scratch` OCI image whose only content is a VM disk file, so a registry can distribute disk images the same way it distributes containers |
| CSB | "Corporate Standard Build" — [redhat-et/openclaw-csb](https://github.com/redhat-et/openclaw-csb), the external project whose published image tank-os runs as its OpenShell sandbox workload |
| OpenShell gateway | The host-side daemon with real Podman access; creates and manages sandboxes |
| OpenShell supervisor | The in-sandbox process (root, briefly) that drops privileges and enforces filesystem/process/network policy before the sandboxed workload runs |
| Hummingbird | Red Hat's project producing minimal, frequently-patched base images (productized as Red Hat Hardened Images) |

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
