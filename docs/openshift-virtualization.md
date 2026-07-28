# OpenShift Virtualization: per-user provisioning

This packages tank-os as a KubeVirt `containerDisk` and automates
per-user VM provisioning via ArgoCD, so onboarding a user means adding
one line to a list, not manually creating a VM.

**Status: authored, not yet deployed against a live cluster.** No
OpenShift Virtualization (CNV)-capable cluster with bare-metal nodes was
available while writing this (same gap as the original smoke test — see
`tank-os-smoke-test-summary.md`). Everything below has been validated
locally (`kustomize build`, manual patch-rendering simulation, `oc apply
--dry-run=client`), not against a real ArgoCD/KubeVirt install. See "First
real cluster test" at the end for what to run the moment cluster access
exists.

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
make build-qcow2                 # produces out-tank-os/qcow2/disk.qcow2
make build-containerdisk         # wraps it (needs the qcow2 above first)
make push-containerdisk          # needs IMAGE_CONTAINERDISK_URI to actually exist as a repo
```

`IMAGE_CONTAINERDISK_URI` defaults to `quay.io/redhat-et/tank-os-containerdisk`
— that repo doesn't exist yet. Create it the same way as
`tank-claw-openshell` earlier (public read, robot account push) before
running `push-containerdisk` for real.

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

Once a CNV-capable cluster (OpenShift Virtualization operator installed,
bare-metal-capable nodes) is available:

1. Confirm OpenShift GitOps (ArgoCD) is installed:
   `oc get csv -n openshift-gitops-operator`.
2. Replace `REPLACE_WITH_YOUR_PUBLIC_KEY` in
   `deploy/applicationset.yaml`'s patch (and in `deploy/base/virtualmachine.yaml`,
   used only if the patch doesn't apply for some element) with a real key.
3. Build, publish, and confirm the containerDisk pulls:
   `make build-qcow2 build-containerdisk push-containerdisk`, then
   `podman pull $(IMAGE_CONTAINERDISK_URI):latest` from a clean environment
   to confirm public read access.
4. `oc apply -f deploy/applicationset.yaml` and watch
   `oc get applications -n openshift-gitops` for sync health.
5. Confirm the namespaces (`tank-alice`, `tank-bob`, ...) were created
   and each has a `VirtualMachine`/`VirtualMachineInstance` reaching
   `Running`.
6. SSH into one VM and confirm `hostname` matches
   (`tank-alice`, not `tank`) and OpenClaw/OpenShell come up the same way
   verified in `docs/openshell.md`'s manual test.
7. Edit the `ApplicationSet` to add a throwaway test user, confirm ArgoCD
   creates the new `Application`/namespace/VM without touching the
   existing ones, then remove it again to confirm cleanup
   (`prune: true` should delete the namespace's resources — verify it
   doesn't orphan anything).
