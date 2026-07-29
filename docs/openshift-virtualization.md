# OpenShift Virtualization: per-user provisioning

This packages tank-os as a KubeVirt `containerDisk` and automates
per-user VM provisioning via ArgoCD, so onboarding a user means adding
one line to a list, not manually creating a VM.

**Status: confirmed working end to end on a live OpenShift Virtualization
cluster** (OpenShift Virtualization 4.21.13, 2026-07-29), including the
full ArgoCD `ApplicationSet` path — not just a direct `oc apply` of the
`VirtualMachine` manifest. `oc apply -f deploy/applicationset.yaml`
generated per-user `Application`s, each with its own namespace and a
`Running`/`Ready` VM; cloud-init applied the injected SSH key and hostname
correctly for each user; and the OpenClaw/OpenShell bootstrap sequence came
up the same way it does under QEMU/Lima. Three real bugs turned up during
this testing and are fixed as of this doc — see "What broke on a real
cluster" and "First real cluster test" below for what was found and what's
still an open, documented gap (namespace cleanup on user removal).

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
make push-containerdisk-arch     # pushes under :$(ARCH), NOT plain :latest -- see below
```

The example above targets `quay.io/redhat-et` — the real shared namespace
these images are published under — so it deliberately uses
`push-containerdisk-arch` rather than plain `push-containerdisk`:
`quay.io/redhat-et/tank-os-containerdisk:latest` is a real multi-arch
manifest list, and pushing a single-arch build straight to that tag would
silently replace it, breaking every other architecture's pull. Finish the
publish with the manifest-merge steps in "Publishing a multi-arch
containerdisk" below. If you're instead pushing to your own personal
`IMAGE_REGISTRY`/`IMAGE_NAMESPACE` override with no existing multi-arch
manifest to protect, plain `make push-containerdisk` (straight to
`:latest`) is simpler and fine.

All three registry repos (`tank-os`, `tank-claw-openshell`,
`tank-os-containerdisk`) already exist under `quay.io/redhat-et` with
public read and robot-account push access. Publishing the bootc `tank-os`
image itself isn't required for `build-qcow2` to work (that target reads
from local Podman storage via `--local`), but it's what makes
`bootc switch`/`bootc upgrade` in-place updates possible on already-running
VMs (see `docs/build.md`'s "Upgrade A Running VM"), and lets this whole
pipeline be reproduced from a different machine or CI runner instead of
requiring the exact local build state.

### Publishing a multi-arch containerdisk

All three published tags are real multi-arch manifest lists (see "What
broke on a real cluster" below for why this matters) — `make
push-containerdisk` as shown above only pushes whatever single
architecture you built locally, and pushing that straight to `:latest`
would silently replace the manifest list with a single-arch image
(`make` prints a warning at that exact point). To publish a genuine
update covering both architectures, build each on its own native host
(cross-arch emulation works but is slow) and merge them:

```bash
# On an arm64 host:
make build-containerdisk push-containerdisk-arch   # pushes :$(ARCH), i.e. :arm64

# On an amd64 host:
make build-containerdisk push-containerdisk-arch   # pushes :amd64

# From either host, once both arch tags exist in the registry:
podman manifest create quay.io/redhat-et/tank-os-containerdisk:latest \
  docker://quay.io/redhat-et/tank-os-containerdisk:arm64 \
  docker://quay.io/redhat-et/tank-os-containerdisk:amd64
podman manifest push --all quay.io/redhat-et/tank-os-containerdisk:latest \
  docker://quay.io/redhat-et/tank-os-containerdisk:latest
```

This is exactly the procedure used to fix the multi-arch bug below —
confirmed working by rebuilding on a native x86_64 host and merging with
the existing arm64 image.

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

These two commands are what's checkable *without* a live cluster (`oc
apply --dry-run=client` only validates well-formed YAML, not the actual
`VirtualMachine` CRD schema). Full CRD schema validation needed a real
cluster with KubeVirt installed — that gap is closed; see "First real
cluster test" below for the live `oc apply --dry-run=server` and full
deploy results.

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

The ArgoCD `ApplicationSet` path itself is now also confirmed, same
cluster and session:

- [x] OpenShift GitOps was already installed on this cluster
  (`oc get pods -n openshift-gitops` showed a healthy ArgoCD install; the
  operator's CSV turned up in `openshift-virtualization-os-images`, not
  the `openshift-gitops-operator` namespace the original checklist
  guessed — namespace really does vary by install, don't hardcode it).
- [x] `oc apply -f deploy/applicationset.yaml` (real key substituted,
  `targetRevision` pointed at this branch pre-merge) generated
  `tank-os-alice`/`tank-os-bob` `Application`s, each creating its own
  namespace and a `VirtualMachine` reaching `Running`/`Ready`.
- [x] SSH into both (`virtctl port-forward`) confirmed `hostname` is
  `tank-alice`/`tank-bob` respectively, not `tank` — the JSON6902 patch's
  per-user substitution is correct end to end through ArgoCD's own
  Go-template rendering, not just the manual dry-run simulation done
  earlier.
- [x] Adding a throwaway `carol` entry to the List generator: ArgoCD
  created `tank-os-carol`/namespace `tank-carol`/VM `tank-carol` without
  touching `alice`/`bob`.
- [x] Removing `carol` again: ArgoCD pruned the `Application` and
  everything it tracked inside `tank-carol` (the VM, etc.) — see the bug
  and the known gap below for what this step actually surfaced.

**Bug found and fixed: `goTemplate: true` is required.** The manifest
uses dot-prefixed Go-template syntax (`{{.user}}`) throughout, but this
cluster's ApplicationSet controller doesn't default to that engine —
without `spec.goTemplate: true`, it falls back to a legacy templating mode
that doesn't recognize `{{.user}}` at all and renders it as literal text.
Every generated `Application` then got the identical literal name
`tank-os-{{.user}}`, which ArgoCD rejected outright: `ApplicationSet
tank-os contains applications with duplicate name: tank-os-{{.user}}`.
Fixed by adding `goTemplate: true` (plus the recommended
`goTemplateOptions: ["missingkey=error"]`, so a real typo in a template
key fails loudly instead of silently rendering `<no value>`).

**Known gap, not yet fixed: removing a user leaves an empty namespace
behind.** After pruning `carol`'s `Application`, `tank-carol` the
*namespace* stayed `Active` with zero resources in it — confirmed it
wasn't just mid-termination (checked again after 20+ seconds, still
`Active`). This is standard ArgoCD behavior, not a misconfiguration:
`CreateNamespace=true` is a sync-time side effect, not a resource ArgoCD
tracks and therefore not something `prune: true` cleans up. Cleaned it up
manually (`oc delete namespace tank-carol`) for this test. Removing users
at any real scale will accumulate empty leftover namespaces unless this
gets addressed — options worth evaluating later: an ArgoCD
`PreDelete`/`resource-hook`-based cleanup Job, a periodic sweep for
empty `tank-*` namespaces, or declaring the `Namespace` object as an
actual tracked resource in `deploy/base/` instead of relying on
`CreateNamespace=true` (trades one problem for needing per-user
Kustomize overlays instead of a single shared base, which is exactly the
"N checked-in files" this architecture was designed to avoid — not a
clear win, worth thinking through rather than doing reflexively).
