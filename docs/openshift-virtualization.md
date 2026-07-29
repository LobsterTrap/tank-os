# OpenShift Virtualization: per-user provisioning

This packages tank-os as a KubeVirt `containerDisk` and automates
per-user VM provisioning via ArgoCD, so onboarding a user means adding
one line to a list, not manually creating a VM.

**Status: confirmed working on a live OpenShift Virtualization cluster**
(OpenShift Virtualization 4.21.13, 2026-07-29) — a `VirtualMachine` applied
directly from `deploy/base/` (not yet through the ArgoCD `ApplicationSet`;
see "Still open" below) reached `Running`, cloud-init applied the injected
SSH key and hostname, and the OpenClaw/OpenShell bootstrap sequence came up
the same way it does under QEMU/Lima. Two real bugs turned up and are fixed
as of this test — see "What broke on a real cluster" below.

**Still open:** the ArgoCD `ApplicationSet` itself (`deploy/applicationset.yaml`)
has only been validated locally (`kustomize build`, manual patch-rendering
simulation) — the direct-`oc apply` smoke test validates the `VirtualMachine`
manifest and images, not ArgoCD's own Go-template rendering or the
per-namespace GitOps flow. See "First real cluster test" for what's left.

## What broke on a real cluster (and is now fixed)

- **The published images were arm64-only, not actually multi-arch.**
  `quay.io/redhat-et/{tank-os,tank-claw-openshell,tank-os-containerdisk}`
  had all been built from an Apple Silicon Mac and pushed as plain
  single-architecture images — nothing checked this against a real amd64
  target until this cluster test failed with the VM's guest network never
  coming up (`no route to host` dialing the SSH port; the guest OS never
  actually booted because an aarch64 kernel/bootloader can't run under an
  x86_64 KVM domain, which is what KubeVirt configures on this cluster's
  amd64 nodes). Fixed by building genuine amd64 variants of all three
  images on a native x86_64 host and merging them with the existing arm64
  images into real multi-arch manifest lists (`podman manifest
  create`/`push --all`) under the same tags — `docker`/`podman`/KubeVirt
  now all pull the architecture that matches the node automatically. No
  arch-specific tags needed going forward; keep pushing both architectures
  under the same tag when either image changes.
- **`spec.running: true` is deprecated** in this cluster's KubeVirt version
  (`spec.runStrategy: Always` is the replacement) — `oc apply` warned but
  didn't fail. Fixed in `deploy/base/virtualmachine.yaml`; confirmed via
  `oc apply --dry-run=server` that `runStrategy: Always` validates with no
  warning against the real CRD.

## Connecting to a VM's SSH port

Nothing in this doc previously said *how* to actually reach a VM's SSH
port from outside the cluster — `ssh openclaw@<pod-ip>` doesn't work here,
the VM's pod-network IP isn't routable from your workstation. Use
`virtctl port-forward` (from the `virtctl` CLI, downloadable via
`oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged
-o jsonpath='{.spec.links[*].href}'` for a build matching your OS/arch):

```bash
virtctl port-forward -n <namespace> vmi/<vm-name> 2222:22 &
ssh -p 2222 openclaw@localhost
```

`oc port-forward` does **not** work against a `VirtualMachineInstance`
directly (`oc`'s client-go scheme doesn't know the `kubevirt.io/v1` types) —
this has to be `virtctl`, not plain `oc`/`kubectl`.

## Architecture

One shared `containerDisk` image, N cheap ArgoCD `Application`s — not N
built images and not N checked-in VM manifests:

| Piece | What it does |
| --- | --- |
| `deploy/containerdisk/Containerfile` | Wraps `make build-qcow2`'s output (`FROM scratch` + `COPY disk.qcow2 /disk/`), KubeVirt's documented convention. One image, referenced by every VM. |
| `deploy/base/virtualmachine.yaml` | A single KubeVirt `VirtualMachine` template with placeholder tokens (`USER_PLACEHOLDER`) for name/labels/hostname. |
| `deploy/applicationset.yaml` | An ArgoCD `ApplicationSet` with a **List generator** — one entry per user. Each generates an `Application` pointing at `deploy/base/`, patched per user via a JSON6902 Kustomize patch. |

Per-user customization (hostname + VM name/labels) lives entirely in the
`ApplicationSet`'s list — adding a user is a one-line diff, not a new
file or directory. Per the confirmed decisions for this phase: SSH key,
OpenClaw config, and storage/resource sizing are **identical across all
users**, so there's nothing else to parameterize yet.

Hostname is set via `cloudInitNoCloud.userData` (cloud-init's
`set_hostname` module, already confirmed enabled by default in this
image), not baked into the containerDisk — the same image serves every
user, so per-VM values can only be injected at deploy time.

## Building and publishing the containerDisk

```bash
make build IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=redhat-et     # tags quay.io/redhat-et/tank-os:latest
make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=redhat-et      # publishes the bootc image itself
make build-qcow2 IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=redhat-et   # produces out-tank-os/qcow2/disk.qcow2
make build-containerdisk         # wraps it (needs the qcow2 above first)
make push-containerdisk
```

All three registry repos (`tank-os`, `tank-claw-openshell`,
`tank-os-containerdisk`) already exist under `quay.io/redhat-et` with
public read and robot-account push access. Publishing the bootc `tank-os`
image itself isn't required for `build-qcow2` to work (that target reads
from local Podman storage via `--local`), but it's what makes
`bootc switch`/`bootc upgrade` in-place updates possible on already-running
VMs (see `docs/build.md`'s "Upgrade A Running VM"), and lets this whole
pipeline be reproduced from a different machine or CI runner instead of
requiring the exact local build state.

## Adding a user

Edit `deploy/applicationset.yaml`'s List generator:

```yaml
generators:
  - list:
      elements:
        - user: alice
        - user: bob
        - user: carol   # <- add this line
```

ArgoCD picks up the new entry on its next generator refresh and creates
`tank-os-carol` (an `Application`) → namespace `tank-carol` → a
`VirtualMachine` named `tank-carol` with hostname `tank-carol`. Nothing
else needs to change.

## Local validation

```bash
kustomize build deploy/base                    # confirms the base renders as valid YAML
oc apply --dry-run=client -f deploy/applicationset.yaml   # confirms the ApplicationSet YAML itself is well-formed
```

Full KubeVirt CRD schema validation (confirming `VirtualMachine`'s fields
are actually valid per the CRD, not just valid YAML) needs a live cluster
with the KubeVirt CRDs installed — not attempted here.

The JSON6902 patch in `applicationset.yaml` was verified by hand: copied
`deploy/base/virtualmachine.yaml` into a scratch directory, wrote the same
patch with `{{.user}}` manually substituted for `alice`, and confirmed
`kustomize build` renders `metadata.name: tank-alice`, both
`tank-os/user: alice` label locations, and `hostname: tank-alice` inside
`userData` correctly. This isn't the same as ArgoCD's own Go-template
rendering running for real, but it confirms the Kustomize patch mechanics
are sound.

## First real cluster test

Confirmed so far, on a live OpenShift Virtualization 4.21.13 cluster
(2026-07-29):

- [x] Cluster has the KubeVirt CRDs, a `HyperConverged` CR, and schedulable
  nodes (`oc get hyperconverged -A`, `oc get nodes -l
  kubevirt.io/schedulable=true`) — all present and healthy.
- [x] `deploy/base/virtualmachine.yaml` applied directly (`oc apply`, real
  SSH key and namespace substituted for the placeholders) reaches
  `Running`/`Ready` against the real `VirtualMachine` CRD.
- [x] cloud-init applies the injected SSH key and `hostname:` correctly;
  `virtctl port-forward` + `ssh` confirms connectivity (see "Connecting to
  a VM's SSH port" above).
- [x] OpenClaw/OpenShell bootstrap sequence (`bootstrap-openclaw` →
  `bootstrap-openshell-sandbox`) comes up the same way as under QEMU/Lima.
- [x] Multi-arch images (both fixes above) — confirmed by rebuilding amd64
  variants on a native x86_64 host and re-testing after the manifest-list
  fix.

Still to do — the ArgoCD `ApplicationSet` path itself:

1. Confirm OpenShift GitOps (ArgoCD) is installed: `oc get csv -A | grep -i
   gitops` (namespace varies by install — don't hardcode
   `openshift-gitops-operator`, check for it).
2. Replace `REPLACE_WITH_YOUR_PUBLIC_KEY` in
   `deploy/applicationset.yaml`'s patch (and in `deploy/base/virtualmachine.yaml`,
   used only if the patch doesn't apply for some element) with a real key.
3. Update `deploy/applicationset.yaml`'s `repoURL`/`targetRevision` to
   point at wherever these manifests actually live (currently `main` on
   `LobsterTrap/tank-os.git`, which won't have `deploy/` until this PR
   merges) — or target this branch directly for a pre-merge test.
4. `oc apply -f deploy/applicationset.yaml` and watch
   `oc get applications -n openshift-gitops` for sync health.
5. Confirm the namespaces (`tank-alice`, `tank-bob`, ...) were created
   and each has a `VirtualMachine`/`VirtualMachineInstance` reaching
   `Running`.
6. SSH into one VM (via `virtctl port-forward`, see above) and confirm
   `hostname` matches (`tank-alice`, not `tank`) and OpenClaw/OpenShell
   come up the same way verified in `docs/openshell.md`'s manual test.
7. Edit the `ApplicationSet` to add a throwaway test user, confirm ArgoCD
   creates the new `Application`/namespace/VM without touching the
   existing ones, then remove it again to confirm cleanup
   (`prune: true` should delete the namespace's resources — verify it
   doesn't orphan anything).
