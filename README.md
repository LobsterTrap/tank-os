# tank-os

Fedora bootc image for running OpenClaw as a rootless Podman workload.

bootc turns a container image into a bootable, updateable Linux OS image. tank-os
uses it to package Fedora plus a rootless OpenClaw service into one VM, cloud, or
device image.

## Why This Is Useful

tank-os turns OpenClaw into a bootable Linux appliance. You publish one bootc
container image, build it into a cloud image, VM disk, or device image, and boot
machines that come up with the same rootless OpenClaw service every time.

The interesting part is that the OpenClaw runtime, host OS, Quadlet units, CLI
shim, and upgrade path all travel together as one OCI container image.
The mutable parts stay where users expect them: OpenClaw state under
`~openclaw/.openclaw`, API keys in the `openclaw` user's rootless Podman secret
store, and SSH access configured per instance.

That makes tank-os a good fit for:

- local demos that behave like the cloud target
- lab or device fleets where every machine gets its own OpenClaw interface
- sandboxed OpenClaw hosts with a mostly read-only, image-managed OS
- transactional updates through bootc instead of ad hoc host package changes
- per-machine secrets through rootless Podman secrets instead of baked-in API keys
- fast rollback and rebuild loops while developing OpenClaw host integrations

The result is still a normal Fedora system. Users SSH in as `openclaw`, edit
OpenClaw files in `~/.openclaw`, use the host `openclaw` CLI wrapper, and let
systemd/Podman keep the service running.

For test and demo images, `openclaw` is granted passwordless sudo so local
bring-up and bootc update testing are straightforward. For production, run
OpenClaw as an unprivileged service user and use a separate administrative user
or tightly scoped sudo policy for OS management and bootc updates.

## Start Here

- Build the image: [docs/build.md](docs/build.md)
- Run it without building anything: [docs/quickstart-prebuilt.md](docs/quickstart-prebuilt.md)
- Configure login access: [docs/provisioning.md](docs/provisioning.md)
- Use the OpenClaw CLI: [docs/cli.md](docs/cli.md)
- Configure model provider keys: [docs/model-providers.md](docs/model-providers.md)
- Configure service-gator: [docs/service-gator.md](docs/service-gator.md)
- Deploy per-user VMs on OpenShift Virtualization: [docs/openshift-virtualization.md](docs/openshift-virtualization.md)

For bootc concepts and day-2 operations, see the upstream [bootc documentation](https://bootc-dev.github.io/bootc/).
For disk image builds, see the [Podman Desktop BootC extension](https://github.com/podman-desktop/extension-bootc)
and [bootc-image-builder docs](https://osbuild.org/docs/bootc/).

The host `openclaw` command delegates into the running OpenClaw container. Log in as `openclaw` when manually editing files under `~/.openclaw`.

For a Podman Desktop/macOS VM, see the [local macOS VM access notes](docs/provisioning.md#local-macos-vm) for finding the SSH port or guest IP.

## Agent Prompt

Use this prompt with a coding agent to get oriented and run the local VM flow:

```text
I am working in the tank-os repo. This repo builds a Fedora bootc image that runs OpenClaw as a rootless Podman Quadlet owned by the `openclaw` user. Please help me get a local smoke test running.

Goals:
- Clone the repository `git clone https://github.com/LobsterTrap/tank-os.git` and work from there (cd)
- Build or use the published bootc image `quay.io/sallyom/tank-os:latest` for arm64 or amd64.
- Build a QCOW2 disk image with the Podman Desktop BootC extension or manual bootc-image-builder flow.
- Start the disk image as a Linux VM. On macOS, QEMU with user-mode networking is the most reliable path: `qemu-system-aarch64 -machine virt,highmem=on -accel hvf -cpu host -smp 4 -m 4096 -drive file=disk.qcow2,format=qcow2,if=virtio -drive if=pflash,format=raw,unit=0,file=$(brew --prefix)/share/qemu/edk2-aarch64-code.fd,readonly=on -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::2222-:22 -nographic`. Podman Desktop BootC extension or UTM also work.
- If the default 10 GB disk is too small for the OpenClaw container image (~3.5 GB), resize before first boot: `qemu-img resize disk.qcow2 20G`. XFS grows automatically on next boot.
- SSH in as `openclaw`, verify `sudo -n true`, `sudo bootc status`, `systemctl --user status openclaw.service`, and `podman ps`.
- If the VM is running under Podman Desktop/macadam, find the forwarded SSH port from the `gvproxy` process and use `ssh -i ~/.ssh/id_ed25519 -p <port> openclaw@localhost`. For QEMU with the hostfwd above, use `ssh -i ~/.ssh/id_ed25519 -p 2222 openclaw@localhost`.
- Use an SSH tunnel to open the UI from the host browser: `ssh -N -i ~/.ssh/id_ed25519 -p <port> -L 18789:127.0.0.1:18789 -L 18790:127.0.0.1:18790 openclaw@localhost`, then browse to `http://127.0.0.1:18789`.
- Print the dashboard URL from the VM with `openclaw dashboard --no-open`.
- Configure model provider and service-gator credentials using rootless Podman secrets as the `openclaw` user, then run `tank-openclaw-secrets`.

Post-boot operations (once SSH'd in as `openclaw`):
- The host `openclaw` command delegates into the running container. Use it for all CLI operations: `openclaw gateway status --deep`, `openclaw doctor`, `openclaw dashboard --no-open`, `openclaw devices list`.
- Check service health: `systemctl --user status openclaw.service`, `podman ps`, `podman logs -f openclaw`.
- If the OpenClaw service fails on first boot with a permission error on `~/.openclaw`, fix ownership with `sudo chown -R openclaw:openclaw ~/.openclaw` and restart: `systemctl --user restart openclaw.service`.
- If the service times out pulling the ~3.5 GB container image, pull manually first: `podman pull ghcr.io/openclaw/openclaw:latest`, then restart the service.
- Edit OpenClaw config and workspace files directly under `~/.openclaw/`. Restart the service after config changes: `systemctl --user restart openclaw.service`.
- Create model provider secrets: `printf '%s' "$ANTHROPIC_API_KEY" | podman secret create anthropic_api_key -`, then run `tank-openclaw-secrets` and restart the service. Supported secret names: `anthropic_api_key`, `openai_api_key`, `gemini_api_key`, `google_api_key`, `openrouter_api_key`.
- Create service-gator secrets the same way: `printf '%s' "$GH_TOKEN" | podman secret create gh_token -`. Edit scopes at `~/.config/service-gator/scopes.json`. Then `tank-openclaw-secrets && systemctl --user restart service-gator.service`.
- For low-level debugging, open a shell inside the container: `podman exec -it openclaw sh`.

Constraints:
- Do not bake private keys or API keys into the image.
- Keep OpenClaw state editable under `~openclaw/.openclaw`.
- Prefer rootless Podman for the OpenClaw and service-gator services.
- Use `bootc switch --apply quay.io/sallyom/tank-os:latest` to test image upgrades after the VM is running.

Relevant docs in this repo:
- `docs/build.md`
- `docs/provisioning.md`
- `docs/cli.md`
- `docs/model-providers.md`
- `docs/service-gator.md`
```
