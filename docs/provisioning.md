# Provisioning

tank-os creates the `openclaw` user in the image, but instance access should be configured at provisioning time. Do not bake private SSH keys or passwords into the image.

## Cloud-Init

Use `examples/cloud-init/openclaw-user-data.yaml` as the starting point:

```yaml
#cloud-config
users:
  - name: openclaw
    groups:
      - wheel
    sudo:
      - ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-os

runcmd:
  - [loginctl, enable-linger, openclaw]
```

After boot:

`ssh openclaw@<host>` and [configure the Gateway token.](provisioning.md#gateway-token-setup)

```bash
ssh openclaw@<host>
cd ~/.openclaw
openclaw status --deep
```

The `openclaw` command on the host delegates to OpenClaw as it runs inside the
`tank-csb` OpenShell sandbox (there is no more separate "OpenClaw container" —
see the known gap noted in [cli.md](cli.md) for the wrapper's current
container-targeting default). See [cli.md](cli.md) for the wrapper behavior
and multi-instance notes.

### First Boot: Image Pull Timeout

CSB's own image (`quay.io/redhat-et/openclaw:csb-<tag>`, pinned by the
`CSB_IMAGE_TAG` build arg in `bootc/Containerfile` — the current default is
`quay.io/redhat-et/openclaw:csb-2026.07.21`) is pulled as part of `openshell
sandbox create --from`, which runs as `openclaw.service`'s `ExecStart` on
every boot. There is no separate `podman pull` step in this flow the way
there was for the old OpenClaw Quadlet — `openshell` manages the fetch
itself. `openclaw.service` sets `TimeoutStartSec=900` (15 minutes) to absorb
a slow first pull; if the pull takes longer than that, the unit fails.

**Workaround**: pre-warm Podman's local image cache before first boot (or
before restarting the service), so `openshell sandbox create`'s own pull is
a no-op:

```bash
ssh openclaw@<host>
sudo -iu openclaw
podman pull quay.io/redhat-et/openclaw:csb-2026.07.21
systemctl --user restart openclaw.service
```

This works because OpenShell's default image-pull policy is `missing` (pull
only when no local copy exists), so a `podman pull` that lands in the same
local Podman storage `openshell sandbox create` reads from is picked up as
already-cached. Use whatever tag matches your `CSB_IMAGE_TAG` build arg if
you've overridden the default. Once cached, subsequent restarts are fast.

## EC2

Use the cloud-init YAML as EC2 user data. Replace the public key placeholder before launch.

If you want EC2 key-pair injection, verify the selected image/cloud-init path injects the key for `openclaw`. The explicit `ssh_authorized_keys` entry is the most predictable path for this image.

Connect with:

```bash
ssh openclaw@<ec2-public-ip>
```

For browser access to the local-only gateway, use an SSH tunnel:

```bash
ssh -L 18789:127.0.0.1:18789 openclaw@<ec2-public-ip>
```

Then open `http://127.0.0.1:18789`.

## Local macOS VM

Podman Desktop can build a QCOW2 from the bootc image and start it as a local
Linux VM. If you use the Podman Desktop bootc image builder's user form, set the
user to `openclaw` and paste your SSH public key there. That build-time config
is enough for a local test and you do not need a separate cloud-init seed ISO.

The Podman Desktop BootC extension also provides a VM terminal. Use that directly
for a quick demo. Use the SSH flow below when you want a separate macOS terminal
or an SSH tunnel for browser access.

When Podman Desktop starts the VM, it may use `macadam` and `gvproxy` rather than
the normal `podman machine` list. To find the host-side SSH forward:

```bash
ps aux | grep -E 'macadam|gvproxy|bootc'
```

Look for a process like:

```text
/opt/macadam/bin/gvproxy ... -ssh-port 63549 ... bootc-lobster-tank ...
```

Or export the forwarded port directly:

```bash
export PORT="$(
  ps aux |
    grep 'gvproxy' |
    grep 'bootc.*tank' |
    sed -nE 's/.*-ssh-port ([0-9]+).*/\1/p' |
    tail -1
)"
echo "$PORT"
```

Then SSH to localhost on that forwarded port:

```bash
ssh -o ConnectTimeout=5 \
  -i ~/.ssh/id_ed25519 \
  -p "$PORT" \
  openclaw@localhost
```

To access the OpenClaw UI from the macOS host browser, keep an SSH tunnel open
from another terminal:

```bash
ssh -N \
  -o ConnectTimeout=5 \
  -o ExitOnForwardFailure=yes \
  -i ~/.ssh/id_ed25519 \
  -p "$PORT" \
  -L 18789:127.0.0.1:18789 \
  -L 18790:127.0.0.1:18790 \
  openclaw@localhost
```

Then open:

```text
http://127.0.0.1:18789
```

To print the dashboard URL from the VM, run:

```bash
openclaw dashboard --no-open
```

Or run it through SSH from your Mac:

```bash
ssh -i ~/.ssh/id_ed25519 \
  -p "$PORT" \
  openclaw@localhost \
  'openclaw dashboard --no-open'
```

The forwarded port belongs to the macOS host. Do not combine it with the guest
IP address. If you want to use the guest IP directly, use port 22 instead.

To find the guest IP from the serial log, locate the VM log path in the `vfkit`
process:

```bash
ps aux | grep -E 'vfkit|bootc'
```

Look for a path like:

```text
logFilePath=/var/folders/.../macadam/applehv/bootc-lobster-tank.log
```

Then read the log:

```bash
tail -200 /var/folders/.../macadam/applehv/bootc-lobster-tank.log
```

The console prints the NIC address during boot, for example:

```text
enp0s1: 192.168.127.2
```

If that address is reachable from macOS, connect to the guest's normal SSH port:

```bash
ssh -o ConnectTimeout=5 \
  -i ~/.ssh/id_ed25519 \
  openclaw@192.168.127.2
```

For UTM, QEMU, or another local VM manager, attach a NoCloud seed ISO with:

- `user-data` from `examples/cloud-init/openclaw-user-data.yaml`
- `meta-data` from `examples/cloud-init/meta-data`

On macOS, one simple way to create the ISO is:

```bash
tmpdir="$(mktemp -d)"
cp examples/cloud-init/openclaw-user-data.yaml "$tmpdir/user-data"
cp examples/cloud-init/meta-data "$tmpdir/meta-data"
hdiutil makehybrid -iso -joliet -default-volume-name cidata -o tank-os-seed.iso "$tmpdir"
```

Attach `tank-os-seed.iso` to the VM as a CD-ROM/cloud-init seed disk.

## libvirt

With recent `virt-install`, pass the same cloud-init files:

```bash
virt-install \
  --connect qemu:///system \
  --import \
  --name tank-os \
  --memory 4096 \
  --disk /path/to/tank-os.qcow2 \
  --os-variant fedora-unknown \
  --cloud-init user-data=examples/cloud-init/openclaw-user-data.yaml,meta-data=examples/cloud-init/meta-data
```

If your `virt-install` does not support `--cloud-init user-data=...`, attach a NoCloud seed ISO instead.

## Editing OpenClaw Files

OpenClaw runs as the `openclaw` user. The editable state is owned by that user:

```bash
sudo -iu openclaw
cd ~/.openclaw
$EDITOR workspace-*/AGENTS.md
```

Restart the gateway after edits that require a restart:

```bash
systemctl --user restart openclaw.service
```

## Podman Secrets

Create Podman secrets in the `openclaw` user's rootless store.
`bootstrap-csb-sandbox` reads OpenClaw's own secrets directly into the
`tank-csb` sandbox on every start; `tank-openclaw-secrets` handles
service-gator's separately (see "Applying Secrets" below).

### Injecting Secrets From the Host

The sections below assume an interactive session on the VM (`sudo -iu openclaw`
or a direct `ssh openclaw@<host>` login). If you keep credentials on your
development machine instead, you do not need an interactive shell at all —
pipe the value straight to `podman secret create` over SSH:

```bash
printf '%s' "$ANTHROPIC_API_KEY" | ssh openclaw@<host> "podman secret create anthropic_api_key -"
```

Use `printf '%s'`, not `echo`, so the secret does not pick up a trailing
newline. Substitute `<host>` (and any port, e.g. `-p "$PORT"` for the
[local macOS VM](#local-macos-vm) forwarded-port case) with whatever you'd use
to reach the instance elsewhere in this doc. This only works unattended
because the cloud-init template enables lingering for `openclaw`
(`loginctl enable-linger openclaw`); without it, rootless Podman may not have
a runtime session ready for a non-interactive SSH command.

Apply the secret and restart the service the same way:

```bash
ssh openclaw@<host> "systemctl --user restart openclaw.service"
```

Restarting is enough on its own for OpenClaw's own secrets (gateway token,
model-provider keys) — `bootstrap-csb-sandbox` (the `ExecStart` of
`openclaw.service`) reads whichever Podman secrets exist directly on every
restart; there is no separate Quadlet-drop-in-sync step for these anymore.
`tank-openclaw-secrets` (see "Applying Secrets" below) is only needed for
service-gator's own secrets.

Avoid typing the raw secret value directly into a command (it lands in shell
history); export it from a password manager or prompt for it with `read -s`
instead.

### Gateway Token Setup

`bootstrap-csb-sandbox` (the `ExecStart` of `openclaw.service`)
auto-provisions the `openclaw_gateway_token` Podman secret itself on first
start if it doesn't already exist, mirroring the old self-service UX — most
deployments don't need to do anything here.

To set your own value instead (e.g. before first boot, or to pin a
specific token), create the secret before `openclaw.service` first runs:

```bash
sudo -iu openclaw
printf '%s' "$OPENCLAW_GATEWAY_TOKEN" | podman secret create openclaw_gateway_token -
systemctl --user restart openclaw.service
```

The secret is passed into the `tank-csb` sandbox via `openshell sandbox
create --upload` plus a shell wrapper that exports it and removes the
uploaded file before CSB's entrypoint runs — never as a literal CLI
argument or a value written into `openclaw.json`. See
`docs/dev/csb-bootc-deployment-design.md` Finding K for the full mechanism.

### API Key Setup

Execute the following commands to create secrets for Anthropic and OpenAI keys:

```bash
sudo -iu openclaw
printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
printf '%s' "$OPENAI_API_KEY" | podman secret create openai_api_key -
```

Execute the following commands to create secrets for xAI, Mistral, and
Cohere keys (all optional — CSB only reads whichever of these exist):

```bash
sudo -iu openclaw
printf '%s' "$XAI_API_KEY" | podman secret create xai_api_key -
printf '%s' "$MISTRAL_API_KEY" | podman secret create mistral_api_key -
printf '%s' "$COHERE_API_KEY" | podman secret create cohere_api_key -
```

### Applying Secrets

For OpenClaw's own secrets (gateway token and the model-provider keys
above), a plain restart is enough — `bootstrap-csb-sandbox` reads whichever
Podman secrets exist directly on every start, so there is no separate sync
step:

```bash
systemctl --user restart openclaw.service
```

`tank-openclaw-secrets` (`sync-podman-secrets`) is a separate helper scoped
to **service-gator's** secrets only (`gh_token`, `gitlab_token`,
`forgejo_token`, `jira_api_token`) — it writes that container's Quadlet
secret drop-in and no longer touches OpenClaw's own config or secrets:

```bash
tank-openclaw-secrets
systemctl --user restart service-gator.service
```

Do not create these secrets as root unless you intentionally switch to a rootful Podman runtime.

See [model-providers.md](model-providers.md) for the full provider mapping and custom provider examples.
