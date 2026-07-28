# OpenShell sandboxing

[OpenShell](https://github.com/NVIDIA/OpenShell) gives OpenClaw's tool calls
application-layer sandboxing (filesystem, network, process policy) on top
of the kernel isolation the VM itself already provides. tank-os wires it in
as OpenClaw's native sandbox backend rather than running OpenClaw's own
Docker-based sandbox — the two are mutually exclusive in OpenClaw's config
schema (`agents.defaults.sandbox.docker.*` settings are rejected once
`backend: "openshell"` is set), so this replaces OpenClaw's built-in
sandbox entirely, it doesn't wrap it.

## Where each piece runs

- **`openshell-gateway`** runs on the VM host as a rootless systemd *user*
  service under the `openclaw` user (installed via RPM in
  `bootc/Containerfile`, enabled globally so it starts under that user's
  session the same way the Quadlet-generated services do). It's the piece
  that actually creates and manages sandbox containers, using that user's
  rootless Podman — it needs real container-runtime access, which the
  OpenClaw container itself never has.
- **The `openshell` CLI** lives inside the OpenClaw container (see
  `bootc/openclaw-openshell/Containerfile`, a small image layered on top of
  the published `ghcr.io/openclaw/openclaw` image with an SSH client and
  the CLI added). OpenClaw's `openshell` plugin shells out to this CLI
  (`sandbox get`/`sandbox create`/`sandbox ssh-config`) and then opens an
  SSH session into the resulting sandbox — this is why `openclaw.container`
  runs with `Network=host`: the CLI needs to reach the host-side gateway on
  its own loopback address.
- **The sandbox itself** is a container built from
  `ghcr.io/lobstertrap/openshell-hummingbird-images/sandboxes/openclaw`
  (Project Hummingbird-based, rebased from NVIDIA's own Ubuntu-based
  community sandbox images). It's pre-created under a fixed name
  (`tankos-openclaw`) by
  `/usr/libexec/tank-os/bootstrap-openshell-sandbox` before OpenClaw's
  gateway ever starts, so OpenClaw's plugin just finds it via `sandbox get`
  and never needs to invoke `sandbox create` itself.

## First boot sequence

`openclaw.container`'s two `ExecStartPre=` scripts run in order:

1. `bootstrap-openclaw` — writes `openclaw.json` (including
   `agents.defaults.sandbox` and `plugins.entries.openshell`) and a gateway
   token, both only on first run.
2. `bootstrap-openshell-sandbox` — installs the `@openclaw/openshell-sandbox`
   plugin into the persisted `~/.openclaw` volume (has to happen before the
   gateway's first start, since the config written in step 1 already
   references it), waits for `openshell-gateway.service` to be active, and
   pre-creates the sandbox if it doesn't already exist.

Both steps are idempotent — safe to re-run on every boot, cheap no-ops
after the first.

First boot has to pull the derived OpenClaw+OpenShell image and the
`sandboxes/openclaw` image (a few hundred MB) in addition to installing the
plugin, which can take several minutes on a slow connection — this is why
`openclaw.container`'s `TimeoutStartSec` is set generously (900s), the same
"known first-boot gap" pattern already documented for the image-pull
timeout in `docs/provisioning.md`.

## Testing this locally end to end

1. Build and push the derived image first — the main image's Quadlet
   references it by tag, so it has to exist in the registry before
   `make build-qcow2` produces a disk that can actually boot successfully:

   ```bash
   make build-openclaw-openshell
   make push-openclaw-openshell
   ```

1. Build the main image:

   ```bash
   make build
   ```

1. Create `config.toml` with your own SSH key (see `docs/build.md`'s
   "Build A Disk Image With Make" section), then build and resize the
   disk:

   ```bash
   make build-qcow2
   qemu-img resize out-tank-os/qcow2/disk.qcow2 20G
   ```

1. Boot it (see `docs/build.md`'s "Launch on Linux (QEMU)" section for
   the aarch64/macOS invocation) and SSH in as `openclaw`.

1. `openclaw.service` does not auto-start on first boot (a known,
   separate bug — see `tank-os-smoke-test-summary.md` finding #6), so
   start it manually the first time:

   ```bash
   systemctl --user start openclaw.service
   ```

   First boot pulls the derived image and the sandbox image fresh, which
   can take several minutes — `systemctl --user status openclaw.service`
   will show `activating (start-pre)` while
   `bootstrap-openshell-sandbox` is still running. This is normal; wait
   for `active (running)`.

1. Verify the sandbox is actually wired in:

   ```bash
   podman exec openclaw openclaw sandbox explain
   ```

   Look for `backend: openshell` and `runtime: sandboxed` — see
   "Inspecting sandbox state" below for what a healthy report looks like
   and for host-side checks.

## Inspecting sandbox state

From inside the running OpenClaw container:

```bash
openclaw sandbox explain
```

This reports the effective sandbox mode/scope/workspace access and
confirms `backend: openshell` with a healthy sandbox rather than a
fallback/error state.

From the VM host, as the `openclaw` user:

```bash
systemctl --user status openshell-gateway.service
openshell sandbox get tankos-openclaw
```

## Known limitation: network policy enforcement under rootless Podman

The sandbox's egress policy is enforced by an in-container process
(`openshell_supervisor_network`, an OPA-based network supervisor) that
intercepts connections and resolves the calling process's binary path via
`/proc/<pid>/root/...` to match it against `policy.yaml`'s per-host
`binaries` allow-lists. This resolution needs `CAP_SYS_PTRACE`, which
rootless Podman does not grant by default — the sandbox logs a warning
or when it can't do this ("Cannot access container filesystem for symlink
resolution... run with CAP_SYS_PTRACE"), and falls back to literal
path matching.

**This was not fully verified as fail-closed in this session's test
environment** (macOS + QEMU + rootless Podman machine): manual `curl`
attempts to a non-allow-listed host from both `podman exec` and the real
SSH bridge path did not reproduce a denial in that specific setup. This
may be specific to the nested-virtualization test environment, or may
indicate the policy engine needs `CAP_SYS_PTRACE` granted to the sandbox
container to enforce reliably under rootless Podman. **Before relying on
this for the exfiltration-test in the original upgrade plan's Phase 2/5,
re-verify egress denial on a real target host** (bare metal or OpenShift
Virtualization, not nested virtualization on a laptop), and if it's still
not fail-closed, check whether the sandbox Quadlet/container needs
`--cap-add=SYS_PTRACE` added explicitly.

## Adjusting policy

The sandbox's filesystem/network/process policy lives in the
`sandboxes/openclaw` image itself (`policy.yaml`, baked in at image build
time in `openshell-hummingbird-images`), not in tank-os. Changing policy
means rebuilding and re-pinning that image's digest in
`bootstrap-openshell-sandbox`, the same way any other pinned image
reference in this repo gets updated.
