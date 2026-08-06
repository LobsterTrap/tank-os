# OpenClaw CLI

tank-os provides a host-side `openclaw` wrapper at `/usr/local/bin/openclaw`.
It delegates into the running OpenClaw container, so users do not need to install
a separate Node.js/OpenClaw CLI on the host and do not need to open an
interactive shell inside the container for normal operations.

**Known gap since the CSB migration:** the wrapper's default target,
`OPENCLAW_CONTAINER=openclaw`, assumes a container literally named
`openclaw` — a leftover from before OpenClaw ran inside the `tank-csb`
OpenShell sandbox (see `docs/openshell.md`). No container by that exact
name exists anymore; the sandbox's underlying Podman container has a
generated name instead (`openshell-default--tank-csb-<hash>`, find it with
`podman ps`). Until the wrapper is updated to know about `tank-csb`
natively, either:

- point it at the real container explicitly, once per session:
  `export OPENCLAW_CONTAINER=openshell-default--tank-csb-<hash>` (or pass
  `--container openshell-default--tank-csb-<hash>` per invocation), or
- skip the wrapper and go through OpenShell directly:
  `openshell sandbox exec -n tank-csb --no-tty -- openclaw doctor`.

The rest of this page's examples assume one of those two fixes has already
been applied.

For the default instance:

```bash
openclaw gateway status --deep
openclaw doctor
openclaw dashboard --no-open
openclaw devices list
openclaw devices approve <request-id>
```

## Dashboard URL

To print the OpenClaw dashboard URL from the VM:

```bash
openclaw dashboard --no-open
```

If `gateway.auth.token` is configured as a plain token, the URL includes it as a
fragment, for example `http://127.0.0.1:18789/#token=...`. If the token is
SecretRef-managed, OpenClaw intentionally prints a non-tokenized URL and asks you
to use the external token source instead.

### Browser secure-context requirement

Opening the dashboard at the VM's own routable IP (for example
`http://192.168.64.2:18789/`, as vfkit hands out) fails with:

```text
control ui requires device identity (use HTTPS or localhost secure context)
```

This is enforced by the browser, not by OpenClaw's config — device identity
uses Web Crypto APIs that browsers only expose in a "secure context"
(`https:`, or `http://localhost`/`http://127.0.0.1`). Plain `http://` against
any other host, including the VM's LAN/NAT IP, is refused before OpenClaw
even sees a connection attempt. There is no config setting to disable this;
the retired `gateway.controlUi.dangerouslyDisableDeviceAuth` break-glass only
covers migrating browsers that used it in an older release, not new setups.

The fix is an SSH local port-forward so the browser sees `localhost`:

```bash
ssh -L 18789:127.0.0.1:18789 openclaw@<vm-ip>
```

Then open `http://127.0.0.1:18789/` — `openclaw dashboard --no-open`'s
printed token works as-is here since both sides already say `18789`.

**If that SSH command is killed outright** (`zsh: killed ssh -L
18789:127.0.0.1:18789 ...`, no further error) — some corporate security
tooling terminates local port-forwards to this specific port.

The previous workaround for this (editing the OpenClaw Quadlet's `--port`
argument) no longer applies: OpenClaw does not run as a Podman Quadlet
anymore, and there is no `openclaw.container` file on the VM to edit. The
guest-loopback `18789` binding now comes from `openclaw.service`'s
`ExecStartPost=` line (`openshell forward start 18789 tank-csb
--background`, see `docs/openshell.md`), and `openshell forward` requires
the host-side bind port and the sandbox-internal target port to be the
*same* number (see `docs/dev/csb-bootc-deployment-design.md` Open
Question 6) — so remapping away from `18789` end to end would also
require changing the port CSB's own `openclaw gateway` process listens on
inside the sandbox, which is not yet a documented or verified tank-os
capability. The other candidate fallback, `openshell service expose`, was
found to require a browser client certificate that OpenShell doesn't yet
provide a way to obtain, so it isn't a usable substitute either (same Open
Question 6). Treat this as an open gap if your network blocks
port-forwards to `18789` specifically, not a solved workaround today.

The wrapper targets the `openclaw` container by default. To target another
container, either use `--container`:

```bash
openclaw --container openclaw-research doctor
```

or set `OPENCLAW_CONTAINER`:

```bash
export OPENCLAW_CONTAINER=openclaw-research
openclaw doctor
```

For low-level debugging, use OpenShell or Podman directly against the
actual sandbox container (see the known-gap note above for how to find its
name):

```bash
openshell sandbox exec -n tank-csb --no-tty -- sh
podman exec -it openshell-default--tank-csb-<hash> sh
podman logs -f openshell-default--tank-csb-<hash>
```

This is an escape hatch, not the main UX.

## Single Instance And Multiple Instances

The bootc image ships one default OpenShell sandbox and the systemd unit
that (re)creates it:

```text
/usr/lib/systemd/user/openclaw.service   # creates/recreates the sandbox
```

That keeps first boot predictable and gives the machine one obvious gateway,
sandbox, and service name:

```text
tank-csb
openclaw.service
openclaw
```

Multiple instances are still possible, but they should be explicit. A local
multi-instance shape should follow the installer model:

- unique sandbox names, for example `tank-csb-<name>` (passed to `openshell
  sandbox create --name`)
- unique user services, for example `openclaw-<prefix>-<name>.service`
- unique data/secret scoping per sandbox
- unique host-side forwarded ports (`openshell forward start <port>
  <sandbox>`)
- per-instance env/config describing image, providers, and secrets

For tank-os, the likely next step is to add an installer-style `tank-openclaw`
instance manager that writes per-instance systemd units and sandbox
definitions. Until then, the image intentionally starts one default sandbox
and the wrapper can target additional manually-created containers by name
(see the known-gap note above on setting `--container`/`OPENCLAW_CONTAINER`).
