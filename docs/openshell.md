# OpenShell sandboxing

[OpenShell](https://github.com/NVIDIA/OpenShell) gives OpenClaw
application-layer sandboxing (filesystem, network, process policy) on top
of the kernel isolation the VM itself already provides. tank-os runs
OpenClaw itself inside a single OpenShell sandbox, `tank-csb`, built from
[redhat-et/openclaw-csb](https://github.com/redhat-et/openclaw-csb)'s
("CSB," the Corporate Standard Build) own published image — OpenClaw's
tool calls run as ordinary child processes inside that same sandbox,
constrained by the sandbox's own filesystem/network/process policy,
rather than an unsandboxed OpenClaw reaching out over SSH to a second,
separate tool-call sandbox. This is the "one-sandbox model" — see
`docs/dev/csb-bootc-deployment-design.md` Finding C for how this was
confirmed against CSB's own onboarding scripts. It replaces OpenClaw's
own Docker-based sandbox entirely: CSB runs OpenClaw with no
`agents.defaults.sandbox`/`openshell` plugin config at all, since
OpenClaw doesn't need to reach a sandbox — it's already running inside
one.

## Where each piece runs

- **`openshell-gateway`** runs on the VM host as a rootless systemd *user*
  service under the `openclaw` user. The unit file itself
  (`openshell-gateway.service`) ships inside the `openshell-gateway` RPM
  installed in `bootc/Containerfile` — it is not checked into this repo.
  `bootc/Containerfile` only symlinks it into
  `/etc/systemd/user/default.target.wants/` so it starts under that user's
  session the same way the other systemd-managed services do; if you go
  looking for its unit definition, `rpm -ql openshell-gateway` on the built
  image (or the RPM itself) is where to find it, not this repo. It's the
  piece that actually creates and manages sandbox containers, using that
  user's rootless Podman — it needs real container-runtime access, which
  nothing else in this design has.
- **The `openshell` CLI** runs directly on the VM host as the `openclaw`
  user — installed via the same `openshell` RPM in `bootc/Containerfile`
  as the gateway (no separate container needed for it anymore). It's
  invoked by `/usr/libexec/tank-os/bootstrap-csb-sandbox`, the `ExecStart`
  of `openclaw.service` (a plain systemd `--user` unit, not a Podman
  Quadlet — CSB's image is run via `openshell sandbox create`, never
  `podman run` directly), to register OpenShell providers, stage
  non-provider secrets, and create/poll the `tank-csb` sandbox. There is
  no longer a separate "OpenClaw container" for the CLI to live inside —
  CSB's own image is what runs *as* the sandbox now, not something a host
  container connects to.
- **The sandbox itself** is a container created fresh from CSB's own
  published image (`quay.io/redhat-et/openclaw:csb-<tag>`, pinned via the
  `CSB_IMAGE_TAG` build arg in `bootc/Containerfile`/`Makefile` — not a
  tank-os-specific derived image). It's pre-created under the fixed name
  `tank-csb` by `bootstrap-csb-sandbox` every time `openclaw.service`
  starts (delete-then-recreate, not resumed — see "Every-start sequence"
  below), running CSB's own `openclaw gateway` process as the sandbox's
  workload.

## Every-start sequence

Unlike a service that resumes previous state, `openclaw.service` recreates
`tank-csb` from scratch on every start (no dependency on OpenShell's
`StartupResume` — see `docs/dev/csb-bootc-deployment-design.md` Finding
L). Its `ExecStart`, `bootstrap-csb-sandbox`, does five things, all
idempotent except the sandbox itself:

1. Registers the local gateway with the CLI (`openshell gateway add --local
   https://127.0.0.1:17670`), if `openshell status` shows it isn't already.
   `openshell-gateway.service` generates its own mTLS client bundle on first
   start, but nothing else registers it with the CLI — without this step,
   every subsequent `openshell` command in the script fails immediately
   with "No active gateway."
2. Auto-provisions the `openclaw_gateway_token` Podman secret on first
   boot, if it doesn't already exist.
3. Registers/updates OpenShell providers (`openai-claw`, `github-claw`)
   for whichever of CSB's provider-routed credentials (`openai_api_key`,
   `gh_token`) tank-os has a Podman secret for.
4. Stages whichever of CSB's `read_secret()`-routed keys (gateway token,
   and any of the anthropic/gemini-or-google/xai/mistral/cohere keys)
   tank-os has a secret for, via `--upload` plus a shell-wrapper trailing
   command — never via a literal `--env`/`--credential` value, which would
   put the real secret in the process's argv.
5. Deletes any sandbox left over from a prior start, then runs
   `openshell sandbox create` in the background and polls `openshell
   sandbox get tank-csb` until it reports `Ready` (or times out at 600s).

`openclaw.service` itself ships as `Type=oneshot, RemainAfterExit=yes` —
it is *not* what supervises the running gateway day to day. The CLI's
foreground attachment to `sandbox create` is cosmetic (a log-follow, not
the supervised workload — confirmed by killing that process and observing
the sandbox stay `Ready`, Finding L), so ongoing supervision comes from a
separate `openclaw-healthcheck.timer`: every 30 seconds (after a 2-minute
boot grace), `check-csb-sandbox-health` curls the gateway directly and, on
failure, runs `systemctl --user restart openclaw.service`, which re-runs
the whole bootstrap sequence and brings `tank-csb` back to `Ready`.

`openclaw.service`'s `ExecStartPost` also starts the dashboard forward:
`openshell forward start 18789 tank-csb --background`, binding the VM
guest's own loopback `18789` to the sandbox's dashboard port (see
`docs/dev/csb-bootc-deployment-design.md` Open Question 6 for why
`forward`, not `service expose`, was chosen).

Both `openclaw.service` and `openclaw-healthcheck.timer` are enabled at
build time (symlinked into `default.target.wants/`/`timers.target.wants/`
in `bootc/Containerfile`), so this whole sequence runs unattended from
first boot — no manual `systemctl --user start` needed.

First start has to pull CSB's image (a few hundred MB) in addition to
creating the sandbox and installing/staging credentials, which can take
several minutes on a slow connection — this is why `openclaw.service`'s
`TimeoutStartSec` is set generously (900s), the same "known first-boot
gap" pattern already documented for the image-pull timeout in
`docs/provisioning.md`.

## `Network=host` is no longer needed

Earlier revisions of this design ran OpenClaw unsandboxed inside its own
container, which needed `Network=host` so the `openshell` CLI inside that
container could reach `openshell-gateway` on the VM host's loopback
interface. That container is gone: `bootstrap-csb-sandbox` and the
`openshell` CLI now run directly on the VM host (not inside any
container), so there is no longer a container that needs host-networking
just to reach the gateway's control-plane API. The CSB sandbox itself
still gets Podman's normal, isolated per-container network namespace,
with only the specific hosts/binaries its `policy.yaml` and attached
providers allow — a strictly narrower network exposure than the old
shape had.

## Testing this locally end to end

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

1. Boot it — see `docs/build.md`'s "Launch on Linux (QEMU)" section on
   Linux, or "Launch on macOS (Apple Silicon, QEMU + HVF)" on macOS (the
   Linux script is x86_64-only) — and SSH in as `openclaw`.

1. `openclaw.service` and `openclaw-healthcheck.timer` both auto-start on
   first boot (enabled at build time), so no manual start step is needed.
   First boot pulls CSB's image and creates `tank-csb` fresh, which can
   take several minutes — `systemctl --user status openclaw.service` will
   show `activating (start)` while `bootstrap-csb-sandbox` is still
   running. This is normal; wait for `active (exited)`.

1. Verify the sandbox is actually up and healthy:

   ```bash
   openshell sandbox get tank-csb
   openshell sandbox exec -n tank-csb --no-tty -- \
     curl -s -o /dev/null -w 'HTTP_%{http_code}\n' http://127.0.0.1:18789/
   ```

   Look for `Phase: Ready` and `HTTP_200` — see "Inspecting sandbox state"
   below for more checks.

## Inspecting sandbox state

From the VM host, as the `openclaw` user:

```bash
systemctl --user status openclaw.service openclaw-healthcheck.timer
openshell sandbox get tank-csb
openshell sandbox exec -n tank-csb --no-tty -- \
  curl -s -o /dev/null -w 'HTTP_%{http_code}\n' http://127.0.0.1:18789/
```

A healthy sandbox reports `Phase: Ready` and returns `HTTP_200` from the
gateway. `journalctl --user -u openclaw-healthcheck.service` shows the
health-check timer's own restart decisions, if any.

## Known limitation: network policy enforcement under rootless Podman

The sandbox's egress policy is enforced by an in-container process
(`openshell_supervisor_network`, an OPA-based network supervisor) that
intercepts connections and resolves the calling process's binary path via
`/proc/<pid>/root/...` to match it against `policy.yaml`'s per-host
`binaries` allow-lists. This resolution needs `CAP_SYS_PTRACE`, which
rootless Podman does not grant by default — the sandbox logs a warning
when it can't do this ("Cannot access container filesystem for symlink
resolution... run with CAP_SYS_PTRACE"), and falls back to literal
path matching.

**This was not fully verified as fail-closed in this session's test
environment** (macOS + QEMU + rootless Podman machine): manual `curl`
attempts to a non-allow-listed host did not reproduce a denial in that
specific setup. This may be specific to the nested-virtualization test
environment, or may indicate the policy engine needs `CAP_SYS_PTRACE`
granted to the sandbox container to enforce reliably under rootless
Podman. Before relying on this for an exfiltration test, re-verify egress
denial on a real target host (bare metal or OpenShift Virtualization, not
nested virtualization on a laptop), and if it's still not fail-closed,
check whether `tank-csb`'s Podman container needs `--cap-add=SYS_PTRACE`
added explicitly.

## Adjusting policy

`tank-csb`'s filesystem/network/process policy lives in CSB's own image
(`quay.io/redhat-et/openclaw:csb-<tag>`), which tank-os consumes as-is and
does not modify or rebuild (see
`docs/dev/csb-bootc-deployment-design.md`'s Component Roles table).
Changing the baked-in policy means working with CSB upstream
(`redhat-et/openclaw-csb`), not this repo.

For a one-off, per-deployment policy change on an already-running
sandbox, `openshell policy update tank-csb --add-endpoint
host:port:access:protocol:enforcement [--add-allow
host:port:METHOD:path_glob] --wait` live-patches the policy attached to
`tank-csb` without touching the image. See
`docs/dev/csb-bootc-deployment-design.md` Finding J for a concrete
worked example — including the non-obvious gotcha that an endpoint rule
with no explicit `binaries` allowlist silently denies every caller.
