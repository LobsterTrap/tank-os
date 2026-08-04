# Design: tank-os as openclaw-csb's bootc/qcow2 deployment channel

Status: approved direction, not yet implemented. Written to hand off to a
fresh session for implementation planning (`writing-plans` skill or
equivalent) — this doc is meant to be self-contained enough that the next
session doesn't need this conversation's history.

## Summary

[redhat-et/openclaw-csb](https://github.com/redhat-et/openclaw-csb) (the
"Corporate Standard Build," CSB) already implements a hardened,
CI-tested, actively-maintained OpenClaw-inside-OpenShell-sandbox setup for
Red Hat employees' own laptops. tank-os should **stop building its own
parallel OpenClaw+OpenShell integration** and instead become **CSB's
bootc/qcow2 VM distribution channel**: CSB stays the source of truth for
the hardened application content (sandbox policy, credential handling,
image builds/scanning); tank-os supplies the OS/VM packaging layer
(bootc host image, provisioning, hypervisor docs) and runs CSB's existing
published image as its workload, instead of tank-os's own bespoke
derived images.

This gives two deployment options backed by one hardened build: run CSB
directly via Podman on your own laptop (as today), or get the same build
as a disposable, rebuildable bootc VM appliance (tank-os) — a real
security upgrade (VM isolation on top of CSB's own sandboxing) and a
friction reduction (one qcow2/VM artifact instead of a manual local
setup), without either project reinventing what the other already does
well.

## How we got here (context for a fresh reader)

tank-os started this discussion trying to solve one specific problem:
`bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets` injects model
provider keys (`OPENAI_API_KEY`, etc.) as plain env vars directly into the
OpenClaw gateway container — a defense-in-depth concern (least privilege),
not a known exploit. Research to solve *that* narrow problem kept
surfacing bigger, related architecture questions, summarized below as
findings A–H. The end state is the "Summary" above; the findings are kept
here because a fresh session will need them to sanity-check the plan
without redoing this research.

### Finding A — OpenShell's `provider` mechanism is real, and generic

OpenShell has a first-class `provider` abstraction (see
<https://docs.nvidia.com/openshell/sandboxes/manage-providers> and
[NVIDIA/NemoClaw#1841](https://github.com/NVIDIA/NemoClaw/discussions/1841)):
a provider (e.g. `openshell provider create --type openai --credential
OPENAI_API_KEY=...`) is attached to a sandbox at creation time
(`openshell sandbox create --provider my-openai -- <cmd>`). The sandboxed
process's env only ever contains a placeholder
(`openshell:resolve:env:OPENAI_API_KEY`, or the same literal embedded in a
header/query-param/URL-path); OpenShell's TLS-terminating L7 proxy
rewrites it to the real value at egress, failing closed (HTTP 500) if it
can't resolve it. This is generic across credential types — provider
types include `github`, `gitlab`, `copilot`, and a `generic` type, not
just LLM inference providers.

### Finding B — this mechanism is sandbox-scoped, confirmed in current OpenShell source

Checked directly against [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
(main, `b9818619` at time of research): the gRPC call that resolves real
credentials, `GetInferenceBundle`, hard-fails unless the caller presents a
sandbox JWT (`Principal::Sandbox`) —
`crates/openshell-server/src/inference.rs:956,959`, enforced again in
`auth/sandbox_methods.rs:33` and `auth/method_authz.rs:143`. Sandbox JWTs
are minted only through the sandbox lifecycle/bootstrap path
(`architecture/gateway.md:191-207`). There is no standalone/gateway-hosted
credential-injection endpoint a non-sandboxed sibling process can use —
git history shows the mechanism moving *further* into sandbox-local
routing over time (`31d7ca53`/`1ca23bc5`, 2026-03-06), not toward a
decoupled mode.

### Finding C — running the agent inside the sandbox is a ONE-sandbox model, not two

tank-os's current architecture is: OpenClaw runs unsandboxed, and reaches
a *separate* OpenShell sandbox over SSH for each tool call
(`agents.defaults.sandbox.backend: "openshell"`). The question was whether
moving OpenClaw itself inside a sandbox (to use Finding A/B's mechanism
for its own LLM key) would mean *two* sandboxes chained by SSH, or one.

Confirmed it's **one**, across every reference source checked:
- [LobsterTrap/openshell-hummingbird-images](https://github.com/LobsterTrap/openshell-hummingbird-images)'s
  `sandboxes/openclaw-nvidia/openclaw-nvidia-start.sh` and
  `sandboxes/openclaw/openclaw-start.sh` onboard OpenClaw with `--mode
  local` and no `sandbox.backend`/`openshell` plugin config — tool calls
  run as ordinary child processes inside the same sandbox, constrained by
  that sandbox's own `policy.yaml` (filesystem/Landlock/seccomp/network
  policy).
- OpenShell's own `rfc/0011-multi-player-design/README.md:899-928`
  describes the *other* (non-nested) pattern this compares against: an
  unsandboxed OpenClaw with an `openshell` plugin in `mode: "remote"` —
  i.e., today's tank-os shape, not a nested-sandbox shape.
- NemoClaw's `docs/about/how-it-works.mdx` describes a single `SANDBOX`
  node that "runs the selected agent runtime with its NemoClaw integration
  layer, configuration, and supporting tools" — the gateway sits outside
  only to mediate credentials/egress, not to broker a second sandbox.

This means moving OpenClaw inside a sandbox is a genuine simplification of
tank-os's current tool-execution model (collapses "OpenClaw container +
separate tool sandbox + SSH" into one sandbox), not just a credential fix.

### Finding D — NemoClaw itself: real, but not something to depend on directly

NemoClaw (github.com/NVIDIA/NemoClaw) is a CLI+blueprint layer that
automates onboarding OpenClaw into an OpenShell sandbox. Real repo stats
at time of research: 22,049 stars, 301 open issues, self-declared **alpha
/ "Early preview," best-effort maintenance, no SLA**
(`docs/reference/platform-support.mdx:168-171`). Its primary tested path
is exactly the laptop scenario ("Local CLI onboard... Docker available
locally," P0 priority for macOS Apple Silicon and Linux), and it
explicitly treats reboot-survival as non-guaranteed even on its secondary
"headless server" path — but it assumes it's the *outermost* layer
touching Docker on the machine, not something running one level down
inside a VM guest, and there's live churn specifically in the
dashboard/port-forward area (open issues #7227, #7791, #8111 at time of
research). **Recommendation: don't take a runtime dependency on NemoClaw**;
its onboarding *pattern* (provider creation, then forward) is worth
mirroring, but openclaw-csb (Finding G) already does this natively without
NemoClaw, more relevantly to tank-os's situation.

### Finding E — dashboard access is solvable without changing the user-facing flow

tank-os's existing dashboard access pattern, unchanged since before this
discussion, is `ssh -L 18789:127.0.0.1:18789 openclaw@<vm-ip>`
(`docs/cli.md:51`, `docs/provisioning.md:72,132`) — this forwards the
user's local port to the **VM guest's own loopback**, not to a specific
container. As long as whatever serves the dashboard inside the guest is
still reachable at the guest's `127.0.0.1:18789` — e.g. via `openshell
forward start 18789 <sandbox>` or `service expose` bound to that same
guest-loopback port — this exact SSH command, and the browser URL, do not
change. The sandbox boundary is invisible to the end user; only the
existing VM boundary is, and that's already priced into every existing
tank-os doc.

### Finding F — claw-operator-upstream has a mature standalone alternative, not needed here

[codeready-toolchain/claw-operator](https://github.com/codeready-toolchain/claw-operator)
(the Claw Operator, for OpenShift/K8s OpenClaw deployments) solves "keep
the real key out of OpenClaw's env" with a standalone, well-tested Go
proxy (`cmd/proxy/main.go` + `internal/proxy/`, ~3,700 lines including
tests) — a `goproxy`-based MITM forward proxy or a `httputil.ReverseProxy`
"gateway mode," with pluggable injectors per auth scheme (`api_key`,
`bearer`, `oauth2`, `gcp`, `kubernetes`, `path_token`). Its core
(`internal/proxy/`) has no Kubernetes API dependency and would be portable
to a Podman/systemd context; what's K8s-specific is the surrounding
operator/reconciler/NetworkPolicy machinery.

This remains good prior art and a reasonable model for topologies that
*can't* sandbox the agent (which is why it exists for OpenShift/K8s), but
**tank-os doesn't need it**: once OpenClaw runs inside an OpenShell
sandbox (Finding C), OpenShell's own provider mechanism (Finding A) covers
the same need without a new component to build or maintain.

### Finding G — openclaw-csb already builds exactly this, for laptops, in production

[redhat-et/openclaw-csb](https://github.com/redhat-et/openclaw-csb) ("CSB"
= Corporate Standard Build) is a Red Hat project — maintained primarily by
Ryan Cook and Ryan Nix — that runs OpenClaw inside a single OpenShell
sandbox on employees' own macOS/Linux laptops. Confirmed details:

- **One-sandbox model, exactly Finding C's shape.** `scripts/openclaw-csb`
  creates the sandbox with `openshell sandbox create --from <image> ...
  --provider openai --provider github ...`; `csb/entrypoint.sh` execs
  `openclaw gateway --allow-unconfigured` in the foreground inside that
  sandbox — no SSH hop to a second sandbox.
- **Credentials: a real, precedented mixed state, not pure `provider`
  purism.** `openai`/`github` go through OpenShell providers (real
  secrets stay at the OpenShell gateway; the sandboxed process only sees
  placeholders — verified in the README via an `echo $OPENAI_API_KEY`
  check). The gateway bearer token and the remaining model keys
  (anthropic, google, xai, mistral, cohere) go through plain Podman
  secrets read into env vars by `csb/entrypoint.sh`'s `read_secret()`
  function reading `/run/secrets/<name>`. The two paths coexist with no
  stated migration plan — a legitimate incremental state tank-os doesn't
  need to hold itself to a stricter bar than.
- **Dashboard access**: `openshell forward start 18789 openclaw-csb
  --background`, bound to `127.0.0.1` on the laptop directly (no VM
  boundary in CSB's own case).
- **Gateway token storage**: macOS Keychain / Linux Secret Service, via
  `scripts/openclaw-csb`'s host-OS keyring calls — not applicable inside a
  minimal bootc VM guest.
- **Maturity**: pinned commits/digests in `csb/Containerfile` (e.g.
  `OPENCLAW_REF=v2026.7.1`), pinned OpenShell version, multi-arch CI
  (`.github/workflows/build.yml`), Trivy CRITICAL-severity gate, SBOM
  generation (syft), and real automated policy tests via `behave` BDD
  specs (`features/0001-csb-policy.feature`). Actively maintained
  (commits through 2026-07-29 at time of research); issues are disabled on
  the repo, so there's no separate issue tracker to check.
- **No bootc/VM/qcow2 concept anywhere in the project** — confirmed via
  full-repo grep and git log search, zero hits. This idea is genuinely new
  to that project, not something already tried or rejected there.

### Finding H — CSB's images can't themselves become a bootc host OS; a separate bootc host is the right shape

`base/Containerfile` builds from
`registry.access.redhat.com/ubi10/ubi-minimal:10.2`; `csb/Containerfile`
is a 3-stage build off `ubi10/nodejs-22`, `node:24-bookworm-slim`, and
(for its final stage) the image `base/Containerfile` produces
(`quay.io/redhat-et/openshell:base-...`). None of these are bootc-capable
bases (no kernel/bootloader/`bootc` lineage) — UBI-minimal and Node
runtime images aren't designed to boot as a host OS. CSB's own README
states directly: *"This is not an OpenShift deployment"* — it's a plain
multi-arch OCI application image
(`quay.io/redhat-et/openclaw:csb-<arch>-<tag>`,
`quay.io/redhat-et/openshell:base-<arch>-<tag>`), built and pushed via
plain `docker build`/`push` in CI, no `bootc-image-builder` step.

So "add bootc to CSB" cannot mean modifying `csb/Containerfile` into an OS
image. It means a **separate bootc host OS image — tank-os, largely as it
exists today at the OS/provisioning layer** — that runs CSB's existing,
already-published image as its Quadlet workload, the same way tank-os
already runs a container as a Quadlet workload today (just pointed at a
different, better-maintained image and integration).

## The design

### Component roles

| Component | Role | Replaces in tank-os today |
|---|---|---|
| **CSB image** (`quay.io/redhat-et/openclaw:csb-*`) | The actual OpenClaw+OpenShell integration — policy, entrypoint, config generation (`configure-openclaw.mjs`). Consumed as-is; not modified by tank-os. | `ghcr.io/openclaw/openclaw`, tank-os's own derived `tank-claw-openshell` image (`bootc/openclaw-openshell/`), and the separately-pinned OpenShell sandbox image. |
| **OpenShell** (already installed on the tank-os host via RPM, per `docs/openshell.md`) | Sandbox creation/lifecycle, `provider`-based credential resolution, `forward`/`service expose` for dashboard reachability. | Already present in tank-os; role expands from "tool-call sandbox only" to "hosts the CSB sandbox that runs OpenClaw itself." |
| **A new tank-os boot-time bootstrap script** | A non-interactive port of what `scripts/openclaw-csb create` does interactively: registers OpenShell providers from tank-os's existing Podman-secret store (see `docs/provisioning.md`'s Podman Secrets section, including the host-SSH-pipe method added earlier in this effort), creates the CSB sandbox fresh on every boot (mirroring tank-os's existing recreate-on-boot pattern for its current tool-call sandbox — no dependency on OpenShell's `StartupResume`), and starts the dashboard forward bound to the VM guest's own loopback `18789` (Finding E). | `bootstrap-openshell-sandbox`, most of `sync-podman-secrets`, and the `openclaw.container` Quadlet's direct image reference. |
| **A rewritten Quadlet/systemd unit** | Runs the bootstrap script's sandbox-create invocation with the gateway command in the foreground (not backgrounded via `nohup`, unlike the reference scripts in Finding C), so systemd's `Restart=on-failure` supervises the real process, not a detached child. | `openclaw.container`. |
| **Podman secrets for whatever CSB itself doesn't route through a provider** (gateway token, and any model keys CSB handles via `read_secret()` rather than a provider) | Matches CSB's own current mixed state (Finding G) — tank-os doesn't need to be purer than CSB is today. | `sync-podman-secrets`'s existing env-injection Quadlet drop-in generation, narrowed in scope. |
| **service-gator** | Open question — CSB doesn't reference it at all. Needs a decision during implementation planning: keep it for scopes CSB doesn't cover, or retire it in favor of CSB's own `github`/`gitlab` provider types. | Not yet decided; see Open Questions. |

### Data flow

**Boot:**

1. Cloud-init/provisioning happens exactly as documented today
   (`docs/provisioning.md`) — no change to how an operator gets SSH access
   or sets up the `openclaw` user.
2. The new bootstrap unit's `ExecStartPre` registers OpenShell providers
   from whatever Podman secrets already exist (reusing the existing
   `sync-podman-secrets`-style "only wire up what's present" pattern).
3. The bootstrap unit creates the CSB sandbox fresh (`openshell sandbox
   create --from quay.io/redhat-et/openclaw:csb-<tag> --provider ...`),
   destroying/recreating rather than attempting to resume a stopped one.
4. The unit starts (or the sandbox's own entrypoint starts) the dashboard
   forward bound to the guest's loopback `18789`.
5. `openclaw gateway` runs in the foreground as the supervised process;
   systemd `Restart=on-failure` covers crash recovery the same way it does
   today.

**Credential flow:**

1. An operator creates Podman secrets exactly as documented today,
   including the newer host-side SSH-pipe method
   (`docs/provisioning.md#injecting-secrets-from-the-host`,
   `docs/quickstart-prebuilt.md`).
2. The bootstrap script reads those secrets and calls `openshell provider
   create` for the credential types CSB routes through providers
   (`openai`, `github`, and whatever else CSB adds), and continues to
   inject the rest as Podman-secret-backed env vars for whatever CSB
   itself still handles that way (Finding G's mixed state).
3. The sandboxed OpenClaw process, and anything it shells out to for tool
   calls, only ever sees placeholders for provider-backed credentials.

**Dashboard access:** unchanged from the operator's perspective — same
`ssh -L 18789:127.0.0.1:18789` command documented today
(`docs/cli.md`, `docs/provisioning.md`), now landing on OpenShell's
forward/expose instead of directly on the `openclaw.container`'s bound
port (Finding E).

## Open questions for implementation planning

1. **Image content parity.** Does `quay.io/redhat-et/openclaw:csb-<arch>-latest`
   (confirm the exact current tag against openclaw-csb's own README/CI at
   implementation time — tag naming may have moved on since this doc was
   written) cover everything tank-os users currently rely on (OpenClaw version,
   plugin set, any tank-os-specific customizations like alternate sandbox
   tool images)? Needs direct verification — likely the first concrete
   implementation step (see "Suggested first step" below).
2. **service-gator's fate** — keep, retire in favor of CSB's own
   `github`/`gitlab` providers, or out of scope for a first iteration?
3. **Which existing tank-os docs still apply unchanged** (e.g.
   `docs/model-providers.md`'s full provider list,
   `docs/openshift-virtualization.md`'s per-VM deployment model) versus
   need rework once CSB's own opinions about config/providers are in
   place?
4. **Version-cadence coupling.** tank-os would track CSB's release cadence
   (`quay.io/redhat-et/openclaw` tags) instead of controlling its own
   OpenClaw/OpenShell pins directly. Is that acceptable, and how does
   bootc's transactional-update model (`bootc upgrade`) interact with
   "pull a newer CSB image" (`Pull=newer` on the Quadlet, as today)?
5. **Cross-team process.** This depends on the CSB maintainers (Ryan Cook,
   Ryan Nix) being comfortable with tank-os consuming their images this
   way, and on Sally's (tank-os's original author) sign-off on the overall
   pivot — both conversations were planned but not yet held as of this
   doc's writing.
6. **Whether raw OpenShell `forward` or `service expose` is the better fit**
   for binding the dashboard to the guest's loopback (Finding E) — `forward`
   is a generic TCP tunnel closer to tank-os's current mechanism;
   `service expose`'s hostname-based routing is a single-command flow but
   has no documented websocket/secure-context guarantees. Needs a hands-on
   comparison, not just documentation reading.

## Suggested first implementation step

Before any bootc/Quadlet rewrite: manually boot a tank-os VM, install
OpenShell (already done today per `docs/openshell.md`), and by hand create
a sandbox from `quay.io/redhat-et/openclaw:csb-<arch>-latest` (confirm exact
tag against the repo at the time) with the necessary
`--provider` flags, then verify (a) the dashboard is reachable through the
existing SSH-tunnel pattern once forwarded to guest-loopback `18789`, and
(b) the image's actual OpenClaw version/plugin set meets tank-os's current
needs. This validates Open Questions 1 and 6 cheaply, before committing to
rewriting `bootstrap-openshell-sandbox`, the Quadlet units, or
`sync-podman-secrets`.

## Explicitly out of scope for this doc

- The credential-injection-proxy design that was explored earlier in this
  effort (Finding F) — not being pursued for tank-os; kept here only as
  context for why it was ruled out.
- Any changes to CSB's own repository or Containerfiles — this design
  treats CSB's image as an external, unmodified dependency.
