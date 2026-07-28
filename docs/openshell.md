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
  (`tank-os-openclaw-sandbox`) by
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
openshell sandbox get tank-os-openclaw-sandbox
```

## Adjusting policy

The sandbox's filesystem/network/process policy lives in the
`sandboxes/openclaw` image itself (`policy.yaml`, baked in at image build
time in `openshell-hummingbird-images`), not in tank-os. Changing policy
means rebuilding and re-pinning that image's digest in
`bootstrap-openshell-sandbox`, the same way any other pinned image
reference in this repo gets updated.
