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

```bash
ssh openclaw@<host>
cd ~/.openclaw
openclaw status --deep
```

The `openclaw` command on the host delegates to the running OpenClaw container.
See [cli.md](cli.md) for the wrapper behavior and multi-instance notes.

### First Boot: Image Pull Timeout

The OpenClaw gateway container (`ghcr.io/openclaw/openclaw:latest`) is ~900MB. 
On first boot, systemd starts the service while pulling the image. If the pull 
takes longer than the default 5-minute timeout, the service fails.

**Workaround**: Pre-pull the image before or after first boot:

```bash
ssh openclaw@<host>
sudo -iu openclaw
podman pull ghcr.io/openclaw/openclaw:latest
systemctl --user restart openclaw.service
```

Once cached, subsequent restarts are instant. Alternatively, increase the systemd 
timeout in the image customization (future PR).

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

Create Podman secrets in the `openclaw` user's rootless store:

```bash
sudo -iu openclaw
printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -
printf '%s' "$OPENAI_API_KEY" | podman secret create openai_api_key -
```

Then sync the generated Quadlet drop-ins and OpenClaw SecretRefs:

```bash
tank-openclaw-secrets
systemctl --user restart openclaw.service
```

The helper only writes references. It does not copy secret values into `openclaw.json`.

Do not create these secrets as root unless you intentionally switch to a rootful Podman runtime.

See [model-providers.md](model-providers.md) for the full provider mapping and custom provider examples.
