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

### Finding I — hands-on validation that OpenShell providers can replace service-gator for GitHub, at least

Personal lab notes at `~/work/learn-openshell/docs/lab/06-providers-and-github-access.md`
(local-only, not published — no `git remote` configured) document a working,
tested GitHub PAT setup via OpenShell's `github` provider type, with
Providers v2 profiles bundling the credential *and* its L7 network policy
together:

- `openshell provider create --name gh-claw --type github --from-existing`
  reads `GITHUB_TOKEN`/`GH_TOKEN` from the environment and stores it at the
  gateway. A sandbox attached with `--provider gh-claw` sees only a
  placeholder (`gh auth status` inside the sandbox shows
  `Token: openshell:resolve:env:v14194160994005896062_GITHUB_*****`, never
  the real PAT).
- **Multiple providers per sandbox is the intended, tested pattern** for
  combining an agent-identity provider (`codex`/`claude`) with a
  service-credential provider (`gh-claw`) on the same sandbox —
  `openshell sandbox create --provider codex --provider gh-claw -- codex`.
  This is exactly tank-os's shape: one sandbox, OpenClaw's own LLM-provider
  credential plus whatever tool-call service credentials it needs.
  Credential env var keys must stay unique across all attached providers.
- **Defense in depth confirmed empirically**: a PAT scoped without
  Contents access still got a real `403` from GitHub on a branch-creation
  call, independent of and in addition to the provider profile's own L7
  policy — the two layers (PAT scope, proxy policy) are genuinely
  independent, not redundant.
- Provider profiles (v2, `providers_v2_enabled`) bundle credentials with
  endpoint `rules`/`access` policy in one reusable YAML, so attaching a
  provider also contributes network policy — a tighter integration than
  service-gator's separate credential-file + MCP-server split.

**Caveat**: this was only tested for GitHub, on a local Podman-driver
gateway (OpenShell 0.0.83). It has *not* been verified for Forgejo or Jira
— per earlier research (Finding A), OpenShell's built-in provider types
include `github` and `gitlab` explicitly, but Forgejo/Jira would need the
`generic` type (custom env var names, no built-in endpoint-policy
template), which is untested here.

**Updates Open Question 2 below**: this is now a strong signal that
**service-gator can likely be retired** in favor of OpenShell providers,
at least for GitHub and GitLab (both built-in types); Forgejo/Jira via
`generic` providers still needs a hands-on check before committing to
dropping service-gator entirely.

## The design

### Component roles

| Component | Role | Replaces in tank-os today |
|---|---|---|
| **CSB image** (`quay.io/redhat-et/openclaw:csb-*`) | The actual OpenClaw+OpenShell integration — policy, entrypoint, config generation (`configure-openclaw.mjs`). Consumed as-is; not modified by tank-os. | `ghcr.io/openclaw/openclaw`, tank-os's own derived `tank-claw-openshell` image (`bootc/openclaw-openshell/`), and the separately-pinned OpenShell sandbox image. |
| **OpenShell** (already installed on the tank-os host via RPM, per `docs/openshell.md`) | Sandbox creation/lifecycle, `provider`-based credential resolution, `forward`/`service expose` for dashboard reachability. | Already present in tank-os; role expands from "tool-call sandbox only" to "hosts the CSB sandbox that runs OpenClaw itself." |
| **A new tank-os boot-time bootstrap script** | A non-interactive port of what `scripts/openclaw-csb create` does interactively: registers OpenShell providers from tank-os's existing Podman-secret store (see `docs/provisioning.md`'s Podman Secrets section, including the host-SSH-pipe method added earlier in this effort), creates the CSB sandbox fresh on every boot (mirroring tank-os's existing recreate-on-boot pattern for its current tool-call sandbox — no dependency on OpenShell's `StartupResume`), and starts the dashboard forward bound to the VM guest's own loopback `18789` (Finding E). | `bootstrap-openshell-sandbox`, most of `sync-podman-secrets`, and the `openclaw.container` Quadlet's direct image reference. |
| **A rewritten Quadlet/systemd unit** | Runs the bootstrap script's sandbox-create invocation with the gateway command in the foreground (not backgrounded via `nohup`, unlike the reference scripts in Finding C), so systemd's `Restart=on-failure` supervises the real process, not a detached child. | `openclaw.container`. |
| **Podman secrets for whatever CSB itself doesn't route through a provider** (gateway token, and any model keys CSB handles via `read_secret()` rather than a provider) | Matches CSB's own current mixed state (Finding G) — tank-os doesn't need to be purer than CSB is today. | `sync-podman-secrets`'s existing env-injection Quadlet drop-in generation, narrowed in scope. |
| **service-gator** | Likely retired. CSB doesn't reference it at all, and Finding I is hands-on-verified evidence that OpenShell's `github`/`gitlab` providers (plus `generic` for anything else) cover the same scoped-credential need natively, with tighter credential+policy bundling than service-gator's separate MCP-server/file-secret split. Confirm Forgejo/Jira via `generic` providers before fully committing. | Likely fully removed; see Finding I / Open Question 2. |

### Data flow

**Boot:**

1. Cloud-init/provisioning happens exactly as documented today
   (`docs/provisioning.md`) — no change to how an operator gets SSH access
   or sets up the `openclaw` user.
2. The new bootstrap unit's `ExecStartPre` registers OpenShell providers
   from whatever Podman secrets already exist (reusing the existing
   `sync-podman-secrets`-style "only wire up what's present" pattern).
3. The bootstrap unit creates the CSB sandbox fresh (`openshell sandbox
   create --from quay.io/redhat-et/openclaw:csb-<tag> --provider ... --
   /app/entrypoint.sh` — the trailing `-- /app/entrypoint.sh` is
   required; see Future consideration 6, verified 2026-08-05, Phase 0
   Task 3 — without it the sandbox comes up idle instead of running
   CSB's entrypoint/gateway), destroying/recreating rather than
   attempting to resume a stopped one.
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
   implementation step (see "Suggested first step" below). **Verified
   2026-08-05** (Phase 0, Task 1 — findings below); re-check before
   actual implementation since CSB rebuilds daily.

   **2026-08-05 validation spike findings (Phase 0, Task 1):**
   - **`CSB_IMAGE_TAG` to use going forward:
     `quay.io/redhat-et/openclaw:csb-2026.07.21`** (digest
     `sha256:93e5610b1f2a920d37d4ed9c09495d0b86d827c279fcabceb0768082a686c2ad`
     for `linux/arm64`). Use this immutable, date-stamped tag (or the
     digest) in Tasks 3/4 and beyond, not `csb-latest` — CSB rebuilds on
     a daily schedule (see workflow's "Check upstream version" job), so
     `csb-latest` pulled on a different day could silently resolve to a
     different image than the one validated here. This tag was
     *discovered* by resolving `csb-latest` via a live `skopeo
     list-tags`/`skopeo inspect` against `quay.io/redhat-et/openclaw` and
     `podman pull`, then reading off the immutable tag it currently
     pointed to — `csb-latest` itself is not the recommended value.
   - **Tag scheme (confirmed against `redhat-et/openclaw-csb`'s
     `.github/workflows/build.yml` and the live registry query above):**
     the doc's placeholder `csb-<arch>-<date>` guess was close but the
     date segment is zero-padded (`csb-amd64-2026.07.21`, not
     `csb-amd64-2026.7.21`). Multi-arch manifest-list tags drop the arch
     segment entirely (`csb-2026.07.21`, `csb-latest`,
     `csb-git-<short-sha>`, `csb-openclaw-<openclaw-version>`).
   - **Version comparison:** the pulled image reports
     `OpenClaw 2026.7.1 (2d2ddc4)` via `openclaw --version`, and the
     `org.opencontainers.image.version` label is `v2026.7.1` — matching
     tank-os's current pin (`ARG OPENCLAW_REF=2026.7.1` in
     `bootc/openclaw-openshell/Containerfile`) exactly. No version gap
     today; this will drift again as CSB's scheduled build tracks
     upstream releases (see workflow's daily "Check upstream version"
     job), so re-verify at actual implementation time.
   - **Plugin-set comparison:** the CSB image bundles 97 extensions
     under `/app/dist/extensions` (OpenClaw's standard providers/tools —
     `openai`, `anthropic`, `google`, `github-copilot`, `browser`,
     `canvas`, etc.), but **no `openshell` extension is bundled**.
     `openshell-sandbox` appears only inside
     `official-external-plugin-catalog-*.js` (OpenClaw's catalog of
     installable-but-not-bundled external plugins), consistent with
     Finding I / the OpenShell-providers-replace-service-gator evidence
     already in this doc.
   - **CSB force-disables all plugins by default ("naked claw"
     policy) — action item for Tasks 3/4.** The CSB entrypoint
     (`csb/entrypoint.sh` → `csb/configure-openclaw.mjs`) unconditionally
     sets `plugins.enabled = false` with empty `allow`/`deny` lists on
     *every* startup, regardless of what's bundled or previously
     configured — the config is rewritten fresh each run and CSB's
     policy is always restored. This is a bigger behavioral difference
     from tank-os's current setup than the plugin-inventory gap above:
     even after installing `openshell-sandbox` from the catalog, it will
     stay inert unless whoever implements sandbox creation also plumbs
     an explicit allowlist through (`plugins.allow` and/or
     `OPENCLAW_ALLOWED_SKILLS`/`agents.defaults.skills`). Whichever task
     stands up the CSB sandbox with OpenShell providers (Task 3 or 4)
     needs to account for this or the sandbox will silently come up with
     no tools enabled.
   - **SSH client / `openshell` CLI bundling (Finding H redundancy
     check):** `command -v ssh` succeeds (`/usr/bin/ssh`, pulled in
     transitively by the RHEL AI base image, not installed explicitly)
     but `command -v openshell` fails (exit 1) — the `openshell` CLI
     binary is absent. **Verdict: only half redundant.** The SSH-client
     half of `bootc/openclaw-openshell/`'s job is already covered by
     CSB's base image; the `openshell` CLI install step still has to
     happen somewhere. tank-os's derived-image build step can be
     slimmed (drop the `openssh-client` install) but not dropped
     entirely, unless the CLI is installed some other way (e.g. on the
     VM host only, if the design ends up not needing it inside the
     OpenClaw container).
   - **Caveat:** `git clone` of `redhat-et/openclaw-csb` and the
     `podman pull`/`skopeo` registry queries above all succeeded from
     this sandbox, so these findings are directly observed, not
     inferred. The pulled image was `linux/arm64` (this machine's
     default `podman pull` resolution) — behavior was not separately
     verified on `amd64`, though the multi-arch manifest and Containerfile
     show no arch-conditional plugin logic.
2. **service-gator's fate** — Finding I makes retirement the likely
   answer for GitHub/GitLab (hands-on verified for GitHub specifically).
   Remaining work: verify Forgejo/Jira via `generic` providers the same
   way, then decide whether to drop service-gator entirely in this first
   iteration or keep it only for whatever `generic`-provider testing
   doesn't cover.
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
7. **Provider lifecycle across reboots.** **Verified 2026-08-05** (Phase
   0, Task 3 — hands-on against `openshell` 0.0.92 on the Task 2 VM,
   `openai`-type provider, real create/update/removal round-trips). The
   bootstrap script needs an explicit create-then-update pattern, not a
   bare `create` call on every boot:
   - **`openshell provider create --name <X> --from-existing` is not a
     safe get-or-create.** Re-running it unchanged against an existing
     name errors (`provider already exists`, exit 1) instead of
     succeeding or duplicating — `provider list`'s row count correctly
     stayed at 1, so it fails safely, but a bare `create` in
     `ExecStartPre` would fail on every boot after the first.
   - **`openshell provider update <name> --from-existing` is the
     idempotent update path.** After rotating the backing Podman secret
     and re-exporting it, `update --from-existing` bumped the provider's
     `Resource version` from 1 to 2 and stored the new credential value.
     The bootstrap script should do `create ... || update ...` (or check
     existence via `provider get` first), not assume `create` alone is
     idempotent.
   - **Removing the backing Podman secret does not detach or invalidate
     an already-created provider.** `openshell provider create`/`update`
     copy the credential value into OpenShell's own store; it is not a
     live reference to the Podman secret. After `podman secret rm
     test_openai_key`, `openshell provider get test-openai` still
     returned the provider with its last-synced credential, and a CSB
     sandbox created afterward with `--provider test-openai` still
     resolved through it. Re-*syncing* a provider once its secret is
     gone (`update --from-existing`) does fail, but only because
     `openshell` itself then reports "no existing local
     credentials/config found" for the empty value it was handed — see
     the bash caveat immediately below for why the *shell script*
     doesn't fail earlier where you'd expect.
   - **Caveat for whoever writes the bootstrap script, found while
     testing the above:** `export VAR="$(podman secret inspect
     --showsecret ...)"` under `set -euo pipefail` does **not** abort
     the script if the inner command fails — `export` (like `local`/
     `declare`) masks the command substitution's exit status, a known
     bash gotcha. Hands-on repro: `export FOO="$(false)"` under `set
     -euo pipefail` exits 0 with `FOO` empty. Don't rely on `set -e` to
     catch a missing/removed secret at the `export` line; check the
     `podman secret inspect` exit status explicitly first, e.g. `val="$(podman
     secret inspect ...)" || exit 1` split from the `export`.

## Future considerations (not blocking, keep in mind while designing)

Raised after the design above was agreed; none of these need to be
resolved before the first implementation spike, but they should shape how
that spike and later phases are built.

### 1. The exact path from a host credential to an OpenShell provider needs testing

The doc's "Credential flow" section says the bootstrap script "reads
[Podman secrets] and calls `openshell provider create`," but the precise
mechanics of that handoff haven't been tested yet. One proposed path:
host env var → Podman secret (already documented,
`docs/provisioning.md#injecting-secrets-from-the-host`) → **VM env var** →
`openshell provider create --from-existing` (which reads credentials from
the calling process's own environment, per Finding I's
`--from-existing` usage).

Worth testing specifically, since it affects how widely the raw secret is
exposed inside the guest: `--from-existing` needs the real value in the
*bootstrap script's own process environment* at the moment it runs, which
could mean either (a) a genuinely VM-wide env var (broader exposure than
today's container-scoped Podman secret mount), or (b) the bootstrap
script pulling the secret value directly into its own short-lived process
env at the point of use — e.g. via `podman secret inspect --showsecret`
— and never persisting it more broadly, then exporting it just for that
one command and calling `--from-existing`, or the bare `--credential
KEY` form (reads the named var from the calling process's own
environment). **Not** the literal `--credential KEY=VALUE` form with the
real value inlined — that puts the secret in the process's argv, visible
to any local user via `ps` or `/proc/<pid>/cmdline`, which defeats the
narrow-exposure property (b) is trying to preserve. (a) would widen
exposure a different way, VM-wide instead of via argv. This needs a
hands-on check, not a decision made on paper.

### 2. A version-check helper for the bundled OpenClaw/OpenShell versions

Users currently have no easy way to tell whether their running tank-os VM
is on a stale OpenClaw/OpenShell/CSB image version versus what's newly
published. A small helper (in the spirit of the existing
`tank-openclaw-secrets` helper) that prints the currently-running CSB
image tag/digest and (if reachable) the latest published tag would close
that gap — genuinely a UX improvement, not a correctness issue, so it can
land whenever convenient after the core CSB integration is working.

### 3. Sandbox policy review/update workflow, and centralized management is an open question

A suggested workflow: review the current policy → download it to the host
→ edit → upload → restart the sandbox. This covers the single-user/laptop
case reasonably well. What's genuinely unresolved is whether/how IT Ops
would want to manage sandbox policy *centrally* across a fleet of
tank-os VMs (or CSB laptop installs) rather than per-machine — this needs
input from whatever central management tooling Red Hat IT actually uses
(not yet known), and shouldn't be designed against without that input.
Treat as an open question to raise with IT Ops when this becomes
relevant, not something to solve speculatively now.

### 4. OpenShift Virtualization parity (future phase, not v1)

tank-os already has a separate `docs/openshift-virtualization.md` and
`deploy/base/virtualmachine.yaml` for running per-user tank-os VMs on
OpenShift Virtualization. Once the CSB-based design above is working on a
laptop hypervisor, the same qcow2/VM image should in principle work
unchanged on OpenShift Virtualization too — worth explicitly verifying
once the core design is implemented, so users get the same
CSB-in-a-sandboxed-VM experience there as on a laptop, but this is
correctly a later phase, not part of the first implementation.

### 5. No Podman-secret-mounting equivalent exists in `openshell sandbox create`

CSB's own `read_secret()` (Finding G) reads `/run/secrets/<name>` for
keys it doesn't route through an OpenShell provider — notably
`OPENCLAW_GATEWAY_TOKEN`, which `csb/entrypoint.sh` requires on *every*
startup (fatal error otherwise), plus the anthropic/google/xai/mistral/
cohere keys. **Verified 2026-08-05 (Phase 0, Task 3):** neither
`openshell sandbox create --help` nor `openshell --help`'s full command
list (`sandbox`, `service`, `forward`, `logs`, `policy`, `settings`,
`provider`, `gateway`, `status`, `inference`, `doctor`, `term`,
`completions`, `ssh-proxy`) has a `secret` subcommand or `--secret`
flag. The one flag that injects arbitrary env vars, `--env
<KEY=VALUE>`, only accepts the literal-value form — unlike
`--credential`, it has no bare-`KEY` env-lookup form (confirmed:
`--env SOME_KEY` alone errors with `--env expects KEY=VALUE, got
'SOME_KEY'`), so using it for a real secret would put the raw value in
the sandbox-create process's argv, exactly the exposure this doc's
security constraint says to avoid. Hands-on confirmation of the actual
failure mode this causes: creating `csb-spike` and explicitly invoking
the image's real entrypoint (`-- /app/entrypoint.sh`, see item 6 below)
produced `ERROR: OPENCLAW_GATEWAY_TOKEN is required on every startup.
Provide it via -e or --secret openclaw-gateway-token.` — there is no
secure, supported way to satisfy this today. **Flagging for the
follow-up implementation plan, not solved here** per Task 3's scope;
options to evaluate later include mounting a plaintext file via
`--upload` before the entrypoint reads it (weaker than a real secret
mount) or an upstream feature request to OpenShell for a native
`--secret` flag.

### 6. `openshell sandbox create` with no trailing command bypasses CSB's entrypoint entirely

Finding G states CSB's `csb/entrypoint.sh` "execs `openclaw gateway
--allow-unconfigured` in the foreground" inside the container.
**Verified 2026-08-05 (Phase 0, Task 3) that this is only true if
`sandbox create` is given an explicit trailing command that invokes
it.** Run exactly as this doc's Data flow step 3 and Task 3's brief
describe it (`openshell sandbox create --from $CSB_IMAGE_TAG --name
csb-spike --provider test-openai`, no `--` command), the sandbox
reaches `Ready`/`healthy` — but `podman top` on the resulting container
shows only OpenShell's own supervisor
(`/opt/openshell/bin/openshell-sandbox`) plus a keep-alive `sleep
infinity` and an interactive `bash -i`. The image's actual
`ENTRYPOINT` (`/app/entrypoint.sh`, confirmed via `podman inspect` on
the image itself) never runs, so the OpenClaw gateway never starts.
`sandbox create --help` explains why: with no `[COMMAND]...` after
`--`, it "defaults to an interactive shell," silently overriding the
image's baked-in entrypoint rather than composing with it. Re-running
with an explicit `-- /app/entrypoint.sh` does invoke the real
entrypoint (and immediately surfaces item 5's gateway-token gap).
**Action item for the bootstrap script:** `sandbox create` must end
with `-- /app/entrypoint.sh` (or equivalent) to actually run CSB's
startup logic — the bare form in this doc's current Data flow step 3
only produces an idle shell container.

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
