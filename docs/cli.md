# OpenClaw CLI

tank-os provides a host-side `openclaw` wrapper at `/usr/local/bin/openclaw`.
It delegates into the running OpenClaw container, so users do not need to install
a separate Node.js/OpenClaw CLI on the host and do not need to open an
interactive shell inside the container for normal operations.

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
tooling terminates local port-forwards to this specific port. Work around it
by moving the Gateway's own listening port instead of the tunnel's local
side, so `18789` never appears as the tunnel's remote target:

1. On the VM, edit the Quadlet's `--port` argument in
   `/etc/containers/systemd/users/1000/openclaw.container` (`Exec=node
   dist/index.js gateway --allow-unconfigured --bind lan --port 18789` →
   `--port 28789`, or any other free port).
2. `systemctl --user daemon-reload && systemctl --user restart openclaw.service`
3. Tunnel with the ports swapped from the blocked command — local `18789`,
   remote `28789`:
   ```bash
   ssh -L 18789:127.0.0.1:28789 openclaw@<vm-ip>
   ```
4. Open `http://127.0.0.1:18789/` as before. Keeping the *local* side at
   `18789` means `controlUi.allowedOrigins` (which lists
   `http://127.0.0.1:18789`/`http://localhost:18789` by default) doesn't
   need editing — only the origin your browser presents matters, not the
   VM-side port behind the tunnel.

This resets on VM recreation (`bootstrap-openclaw` only sets the default
port/origins on first boot) — redo it if you rebuild the VM and hit the same
block.

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

For low-level debugging, use Podman directly:

```bash
podman exec -it openclaw sh
podman logs -f openclaw
```

The Podman shell path is an escape hatch, not the main UX.

## Single Instance And Multiple Instances

The bootc image ships one default rootless Quadlet:

```text
/etc/containers/systemd/users/1000/openclaw.container
```

That keeps first boot predictable and gives the machine one obvious gateway,
state directory, and service name:

```text
~/.openclaw
openclaw.service
openclaw
```

Multiple instances are still possible, but they should be explicit. A local
multi-instance shape should follow the installer model:

- unique container names, for example `openclaw-<prefix>-<name>`
- unique user services, for example `openclaw-<prefix>-<name>.service`
- unique data directories or volumes
- unique host ports for gateway and bridge
- per-instance env/config describing image, ports, secrets, and token

For tank-os, the likely next step is to add an installer-style `tank-openclaw`
instance manager that writes per-instance Quadlets and SecretRef config. Until
then, the image intentionally starts one default gateway and the wrapper can
target additional manually-created containers by name.
