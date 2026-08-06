# Design: tank-os as openclaw-csb's bootc/qcow2 deployment channel

Status: approved direction; Phase 0 validation spike complete, no known
blockers to starting implementation. The core bet — CSB image +
OpenShell sandbox + providers replacing tank-os's own OpenClaw/OpenShell
integration — holds up hands-on: sandbox creation works (with the
wrapper-command form in Finding K / Future consideration 6), provider
create/update/removal semantics across reboots are now known (Open
Question 7), the dashboard is reachable via `forward` (Open Question 6),
GitHub/Forgejo credential-scoping via providers works end to end (Open
Question 2 / Findings I, J), and there is now a verified-working,
argv-safe way to supply CSB's `OPENCLAW_GATEWAY_TOKEN` via `--upload`
plus a shell wrapper (Finding K, closes out issue #41 and Future
consideration 5) — **confirmed 2026-08-05 to also compose correctly with
`--provider` flags and with multiple simultaneous `--upload` secrets in
one invocation**, the actual production shape the real bootstrap script
needs. One follow-up remains: this was verified against the built-in
`test-openai` provider, not re-run against a Forgejo/GitHub-shaped
provider in the same combined invocation. Two more follow-ups remain
known but non-blocking: GitLab is inferred, not independently hands-on
verified, to behave like GitHub (Open Question 2), and Jira is untested
(Open Question 2). Written to hand off to a fresh session for
implementation planning (`writing-plans` skill or equivalent) — this doc
is meant to be self-contained enough that the next session doesn't need
this conversation's history.

**Implementation status (2026-08-05): code complete, docs synced.** Tasks
1–5 of `docs/superpowers/plans/2026-08-05-csb-bootc-implementation.md`
are done on the `feature/csb-bootc-implementation` branch:
`bootstrap-csb-sandbox`, the `openclaw.service`/`openclaw-healthcheck.
{service,timer}` unit set, a narrowed `sync-podman-secrets`, the cleaned-up
`bootc/Containerfile`/`Makefile`, and this documentation pass all landed
in that branch's commit history (not yet opened as a PR at time of
writing — will merge as whatever PR number GitHub assigns when it's
opened, following on from the already-merged Phase 0 spike pull requests
numbered #39, #40, #42, and #43, referenced throughout the findings
below). Task 6 (end-to-end verification on a real VM) remains
outstanding.

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
dropping service-gator entirely. **Forgejo was hands-on verified in
Phase 0 Task 5 — see Finding J below.**

### Finding J — hands-on validation that `generic` providers can reach a real, plain-HTTP Forgejo instance, but only after non-obvious manual policy authoring

Phase 0 Task 5 (2026-08-05, VM at `192.168.64.2`, OpenShell 0.0.92) tested
the `generic` provider type against a real self-hosted Forgejo instance
(`http://rhel01.internal:3000/` — plain HTTP, no TLS, an internal homelab
host) using a read-write-scoped repository/issues token. **Verdict:
confirmed working end to end via a hand-authored custom provider profile
layered on top of the `generic` type — bare `--type generic` alone never
worked. `generic` needs materially more manual setup than `github`/
`gitlab`, and one step is easy to get wrong silently.**

- **The brief's guessed `--endpoint` flag does not exist.** `openshell
  provider create --type generic --help` exposes no endpoint/policy flag
  at all — only `--credential`, `--config KEY=VALUE`, `--from-existing`,
  `--from-gcloud-adc`, `--runtime-credentials`. `--config endpoint=...`
  is silently accepted and stored under "Config keys" but is **not**
  interpreted as network policy — it's an inert trap, not a working
  substitute.
- **Endpoint/network policy for a custom service is a wholly separate
  mechanism from `provider create`.** Two working paths were found by
  reading `openshell provider profile export github` as a schema
  reference:
  1. Author a full custom provider profile YAML (`credentials` +
     `endpoints`, each endpoint needing `host`/`port`/`protocol`/
     `enforcement` and either `access` *or* `rules` — the two are
     mutually exclusive, confirmed via `provider profile lint`), import
     it with `provider profile import --file`, then `provider create
     --type <profile-id>`. Editing an existing custom profile requires
     `provider profile update` with the profile's current
     `resource_version` (from `provider profile export`) — updates are
     optimistic-concurrency-checked, not free-form overwrites.
  2. Skip profiles entirely and live-patch the policy already attached to
     a running sandbox: `openshell policy update <sandbox> --add-endpoint
     host:port:access:protocol:enforcement [--add-allow
     host:port:METHOD:path_glob] --wait`.
- **The actual blocker, and the main finding: an endpoint rule with no
  explicit `binaries` allowlist silently denies every caller.** A rule
  with `host`/`port`/`rules` (or `access: read-only`) exactly matching
  the request still returned `{"error":"policy_denied"}` from OpenShell's
  own proxy — not Forgejo — across three separate policy revisions
  (`openshell policy get <sandbox>` reported each one `Loaded`/
  `Effective`, and the rule's content, inspected via `policy update
  --dry-run`, looked correct). The built-in `github_api`/`openai_api`
  baseline-policy entries that ship with every sandbox both carry a
  `binaries: [path: /usr/bin/curl]`-style entry that custom rules don't
  get by default. Adding `--binary /usr/bin/curl` to the same
  `--add-endpoint` call immediately fixed it — the exact same request
  that had 403'd three times in a row returned Forgejo's real homepage
  HTML on the next try. **This is the one step Finding I's GitHub test
  never had to discover, because the built-in `github` profile already
  ships a `binaries` entry — `generic` does not, for anything.**
- **Once the `binaries` gap was fixed, the full mechanism matched Finding
  I's GitHub result:**
  - Placeholder substitution confirmed: `sh -c 'echo $FORGEJO_TOKEN'`
    inside the sandbox showed only
    `openshell:resolve:env:v15149966231025703563_FORGEJO_TOKEN`, never
    the real token.
  - A real authenticated call —
    `curl -H "Authorization: token $FORGEJO_TOKEN"
    http://rhel01.internal:3000/api/v1/repos/search` — returned a real
    `200` with the token owner's actual repository data, proving the L7
    proxy resolved the placeholder and forwarded a working credential to
    a plain-HTTP (non-TLS) backend, not just HTTPS ones.
  - **Defense in depth confirmed again, independently**: an earlier call
    to `/api/v1/user` (needs Forgejo's `read:user` token scope, which
    this read-write-on-repositories-and-issues token doesn't have) got a
    real `403` from Forgejo itself
    (`"token does not have at least one of required scope(s):
    [read:user]"`) — the same two-independent-layers pattern as Finding
    I's GitHub PAT-scope result, now confirmed on a second provider type.
  - **Not resolved**: raw-IP-literal policy entries (tried against both
    the Forgejo host's private IP and a public control IP, `1.1.1.1`,
    each with an otherwise-correct rule) still 403'd under the
    pre-`binaries`-fix rule shape and were not retried afterward with
    `binaries` added. Hostname-based entries are the proven, recommended
    path regardless, so this is a minor open sub-question, not a
    blocker.
- **Jira was explicitly not tested** — no test Jira instance or token was
  available in this environment. This is a gap, not a "confirmed
  working" result; do not extrapolate the Forgejo result onto Jira
  without repeating this same hands-on check against a real Jira
  instance/token before committing to dropping service-gator for Jira
  specifically.

### Finding K — `--upload` plus a wrapper command solves the `OPENCLAW_GATEWAY_TOKEN` gap (Future consideration 5 resolved)

**2026-08-05, post-merge follow-up to the Phase 0 spike (tracked in
issue #41):** Future consideration 5 (below) originally concluded there
was no secure way to supply `OPENCLAW_GATEWAY_TOKEN` to `openshell
sandbox create`. Root-caused further and solved.

**Deeper root cause than "missing `--secret` flag":** `/run` itself is
unreachable from inside an OpenShell sandbox — not a plain Unix
permission issue (`stat /run` succeeds and reports `0755 root:root`, but
`ls -la /run` and any write under `/run/` both fail with "Permission
denied," which is *consistent with* OpenShell's own sandbox filesystem
policy denying the path rather than the mode bits, though a masked/
restricted mount would produce the same two symptoms and wasn't ruled
out independently). CSB's `read_secret()` (Finding G) hardcodes
`/run/secrets/<name>` — the Podman-native secrets-mount convention CSB
assumes when run via plain `podman run --secret ...`. That path is
unreachable when CSB runs inside an OpenShell sandbox instead,
independent of whatever CLI flags `openshell sandbox create` does or
doesn't expose. Confirmed hands-on: `openshell sandbox create ...
--upload <file>:/run/secrets/openclaw-gateway-token` fails at the upload
step itself — `tar: openclaw-gateway-token: Cannot open: Permission
denied` — before the entrypoint even runs.

**Working solution:** `openshell sandbox create` has an `--upload
<LOCAL_PATH>[:<SANDBOX_PATH>]` flag (visible in `--help`; Future
consideration 5 below already named this as an *untested* option to
evaluate — this is that evaluation) that copies a local file into the
sandbox's own filesystem *before* the trailing command runs. `/tmp`
inside the sandbox is writable by the sandbox's own user (confirmed:
`drwxrwxrwt`, and the uploaded file landed `-rw-------` owned by the
sandbox user, not root) — unlike `/run`, which is unreachable as above.
Combining `--upload` with a shell wrapper as the trailing command,
instead of invoking `/app/entrypoint.sh` directly, gets the token into
the entrypoint's environment without it ever appearing in `sandbox
create`'s own argv.

**Exactly what was tested** (gateway-token only, no `--provider` flags,
token sourced from a local throwaway file, not yet from a live Podman
secret or combined with providers — see caveats below):

```bash
TMPFILE=$(mktemp); chmod 600 "$TMPFILE"
openssl rand -hex 24 > "$TMPFILE"   # throwaway value for this test only
openshell sandbox create --from quay.io/redhat-et/openclaw:csb-2026.07.21 \
  --name gwtoken-spike5 --no-tty \
  --upload "$TMPFILE:/tmp/gwtoken" \
  -- sh -c 'export OPENCLAW_GATEWAY_TOKEN="$(cat /tmp/gwtoken)"; rm -f /tmp/gwtoken; exec /app/entrypoint.sh'
rm -f "$TMPFILE"
```

**Confirmed end to end**: the gateway logged `[gateway] ready` and
`openshell sandbox exec -n gwtoken-spike5 -- curl ... http://127.0.0.1:18789/`
returned `200`. The uploaded file is removed from the sandbox's own
filesystem (`rm -f /tmp/gwtoken`) before CSB's entrypoint or the gateway
process starts, so it's a short-lived, sandbox-local file, never in any
process's argv (`--upload` transfers file *content* over the
SSH/tar channel; only the local, host-side path appears as a CLI
argument) and readable only by the sandbox's own user (`0600`) for the
brief window before deletion — a materially stronger position than the
literal `--env KEY=VALUE` workaround Task 4 used for validation only.

**Production form** — how the real bootstrap script sources the value
from an actual Podman secret and attaches providers in the same command:

```bash
TMPFILE=$(mktemp); chmod 600 "$TMPFILE"
podman secret inspect --showsecret --format '{{.SecretData}}' openclaw-gateway-token > "$TMPFILE"
openshell sandbox create --from quay.io/redhat-et/openclaw:csb-2026.07.21 \
  --name csb-workload --provider ... \
  --upload "$TMPFILE:/tmp/gwtoken" \
  -- sh -c 'export OPENCLAW_GATEWAY_TOKEN="$(cat /tmp/gwtoken)"; rm -f /tmp/gwtoken; exec /app/entrypoint.sh'
rm -f "$TMPFILE"
```

**Confirmed 2026-08-05: `--upload` + `--provider` + multiple secrets in
one invocation all compose correctly.** Two follow-up spikes against the
same VM, using the pre-existing `test-openai` provider (no new
credential needed — this tests the mechanism, not Forgejo specifically):

1. `--provider test-openai --upload <throwaway-token>:/tmp/gwtoken` plus
   the same shell wrapper: sandbox reached `Ready`, and a
   `sandbox exec ... curl http://127.0.0.1:18789/` from inside it
   returned `200` — the provider's credential and the uploaded token
   coexist without conflict, and attaching a provider doesn't interfere
   with the entrypoint-bypassing wrapper command.
2. Two simultaneous `--upload` flags (`/tmp/gwtoken` and a second
   throwaway secret at `/tmp/xtrakey`), each with its own `export ...;
   rm -f ...` line in the wrapper, alongside `--provider test-openai`:
   both files uploaded, both env vars exported, gateway logged
   `[gateway] ready` and resolved `openai/gpt-5.5` as its agent model
   (proving the provider's key was live at the same time as both
   uploaded secrets). Both spike sandboxes were deleted after
   verification.

**Generalizes to every other `read_secret()`-routed key** (the
anthropic/google/xai/mistral/cohere keys CSB doesn't route through a
provider) via the same pattern: one `--upload` per secret, one `export
...; rm -f ...` line per secret in the wrapper, before the final `exec
/app/entrypoint.sh`. This is the pattern the real bootstrap script
(replacing `bootstrap-openshell-sandbox`) should use for whatever
credentials CSB itself expects via `/run/secrets/*` rather than a
provider. Not yet re-verified against a real Forgejo/GitHub provider in
this exact combination (only `test-openai` was used) — the provider
*type* shouldn't matter to this mechanism, but that's an assumption, not
a re-run test.

**Still not re-verified:** whether `--upload`'s stated `.gitignore`
filtering (per `--help`) affects single-file uploads (it appears
scoped to directory uploads, but wasn't explicitly tested against a
single file). The tested command also included `--no-tty` (needed to
capture the entrypoint's stdout for this investigation); this shouldn't
affect a systemd-supervised production invocation but wasn't tested
without it.

### Finding L — the `sandbox create` CLI process is not the supervised workload; systemd needs a create-then-poll oneshot plus a health-check timer

**2026-08-05, Task 2 of the implementation plan.** The Component Roles
table below states this unit's `ExecStart` process IS the real supervised
workload — an assumption Phase 0 never actually tested. Before locking in
the unit shape, this was settled empirically on the VM using Task 1's
actual `bootstrap-csb-sandbox` script (not a hand-typed reconstruction of
the simpler command this doc originally assumed).

**Test:** ran the script to bring up `tank-csb`, confirmed `Ready` and a
`200` from the gateway, found the script's own `openshell sandbox create
... -- sh -c '...'` process via `pgrep -af`, then sent it a plain `kill`
(not a dropped SSH session) — the same signal `systemctl stop` or a crash
would deliver:

```
$ pgrep -af "sandbox create.*tank-csb"
95935 openshell sandbox create --from quay.io/redhat-et/openclaw:csb-2026.07.21 --name tank-csb ...
$ kill 95935
```

**Result, 3 seconds later:** `openshell sandbox get tank-csb` still
reported `Phase: Ready`, and `openshell sandbox exec -n tank-csb --no-tty
-- curl ... http://127.0.0.1:18789/` still returned `200`. Killing the CLI
process had no effect on the sandbox or its gateway — the CLI's foreground
attachment to `sandbox create` is cosmetic (a log-follow), not the
supervised process. The actual `openclaw` workload lives in CSB's own
container runtime behind OpenShell's gateway, entirely independent of
whether anything on the host is still attached to the CLI invocation that
created it.

**Conclusion:** the "direct supervision" unit shape (`Type=simple`,
`ExecStart=` the bootstrap script, letting systemd track that process as
the service) cannot work — systemd would have nothing meaningful to
supervise once `create` returns or is killed, and `Restart=on-failure`
would never fire for a wedged or unhealthy sandbox. `bootstrap-csb-sandbox`
was changed accordingly: its final step now backgrounds `sandbox create`,
polls `sandbox get` for `Ready` (bounded at 600s), then exits — a oneshot,
not a long-running foreground process. `openclaw.service` ships as
`Type=oneshot, RemainAfterExit=yes`, with a separate
`openclaw-healthcheck.timer` (every 30s, after a 2-minute boot grace)
curling the gateway directly and calling `systemctl --user restart
openclaw.service` on failure — this is what actually provides ongoing
supervision, not systemd's built-in process tracking. End-to-end validated
on the VM: with the unit installed as a user service, deleting `tank-csb`
out from under it (simulating a crash) and then running the health-check
script triggered `systemctl --user restart openclaw.service`, which
re-ran `bootstrap-csb-sandbox` and brought `tank-csb` back to `Ready`
(exercising the same delete-then-poll-until-gone recreate path Finding K's
script already relies on for every start).

### Finding M — end-to-end verification on the shared dev VM confirmed the design works, with two environment-driven test-method caveats, a resolved port-collision risk, and one welcome surprise

**2026-08-05/06, Task 6 of the implementation plan (final verification,
two review rounds — the first round's narrative-only writeup of this
Finding was found to lack the raw evidence this doc's other findings
hold themselves to; this text is the corrected, evidence-backed
version).** Applied the actual current-checkout files
(`bootstrap-csb-sandbox`, `sync-podman-secrets`, `check-csb-sandbox-health`,
`openclaw.service`, `openclaw-healthcheck.service`/`.timer`) to the same
shared dev VM prior tasks used, and ran Task 6's exact fresh-boot,
dashboard-reachability, and double-restart checks against them.

**Result: all functional acceptance criteria passed.** Raw evidence for
each:

**(a) Fresh-boot token auto-provisioning.**

```text
$ podman secret ls
... openclaw_gateway_token  file  20 minutes ago  20 minutes ago ...
$ podman secret rm openclaw_gateway_token
1a475e93bfdd60280cb069ecf
$ podman secret ls
# (openclaw_gateway_token row now absent)
$ systemctl --user restart openclaw.service
$ systemctl --user status openclaw.service --no-pager -l
● openclaw.service - OpenClaw gateway inside a CSB OpenShell sandbox ...
     Active: active (exited) since Thu 2026-08-06 00:59:07 UTC; 14ms ago
    Process: 124880 ExecStart=.../bootstrap-csb-sandbox (code=exited, status=0/SUCCESS)
    Process: 125313 ExecStartPost=/usr/bin/openshell forward start 18789 tank-csb --background (code=exited, status=0/SUCCESS)
Aug 06 00:58:50 tank podman[124892]: ... secret create 85fabc3961f5601f5ab62ab97
Aug 06 00:58:50 tank bootstrap-csb-sandbox[124918]: ✓ Updated provider openai-claw
Aug 06 00:58:50 tank bootstrap-csb-sandbox[124941]: ✓ Updated provider github-claw
Aug 06 00:59:07 tank openshell[125313]: ✓ Forwarding port 18789 to sandbox tank-csb in the background
Aug 06 00:59:07 tank systemd[1039]: Finished openclaw.service ...
$ podman secret ls
... openclaw_gateway_token  file  17 seconds ago  17 seconds ago ...
```

`RemainAfterExit=yes` (`active (exited)`), a brand-new secret ID
(`85fabc39...`, replacing the removed `1a475e93...`), and the journal's
own provider-update and forward-start lines confirm the fresh-boot path
runs for real, not just "should work per the script."

**(b) `tank-csb` reaching `Ready`** — literal `openshell sandbox get
tank-csb` immediately after the restart above (policy body omitted, same
shape as Finding L/K's, unchanged):

```text
Sandbox:
  Id: a27ad971-16a5-456d-99db-1d316580e26a
  Name: tank-csb
  Phase: Ready
  Resource version: 9
```

**(c) Dashboard reachability** — literal commands and full output,
internal and host-level:

```text
$ openshell sandbox exec -n tank-csb --no-tty -- curl -s -o /dev/null -w "HTTP_%{http_code}\n" http://127.0.0.1:18789/
HTTP_200
$ curl -s -o /tmp/dash.html -w "HTTP_%{http_code}\n" http://127.0.0.1:18789/
HTTP_200
$ head -5 /tmp/dash.html
<!doctype html>
<html data-openclaw-terminal-enabled="false" lang="en">
  <head>
    <meta charset="UTF-8" />
```

**(d) Double-restart idempotency** — two consecutive
`systemctl --user restart openclaw.service` runs, each followed
immediately by `openshell sandbox get tank-csb` and a dashboard curl,
the same way Task 1's fix round proved this property with real UUIDs and
timestamps:

```text
$ date -u && systemctl --user restart openclaw.service && openshell sandbox get tank-csb
Thu Aug  6 00:59:36 UTC 2026
  Id: 775c1e77-d72b-48d3-8e3d-e4b3bd490c06
  Phase: Ready
$ curl -s -o /dev/null -w "HTTP_%{http_code}\n" http://127.0.0.1:18789/
HTTP_200

$ date -u && systemctl --user restart openclaw.service && openshell sandbox get tank-csb
Thu Aug  6 01:00:32 UTC 2026
  Id: 6c78122c-1df9-4c88-ae46-223f15657fe7
  Phase: Ready
$ curl -s -o /dev/null -w "HTTP_%{http_code}\n" http://127.0.0.1:18789/
HTTP_200

$ openshell sandbox list
NAME      CREATED              PHASE
tank-csb  2026-08-06 01:00:44  Ready
```

Three distinct sandbox instances across this session
(`a27ad971...` → `775c1e77...` → `6c78122c...`), each a fresh `Ready`
sandbox with its own creation timestamp, `sandbox list` showing exactly
one `tank-csb` row after both restarts — no leftover-name conflicts.

**Collision-risk investigation: the pre-existing `tankos-openclaw`
sandbox on host port 18789.** Task 2 found a pre-existing, unrelated
`tankos-openclaw` sandbox on this same shared VM that is *also* `Ready`
and, in Task 2's own words, "serving on the same host-level port 18789
(CSB sandboxes use host networking)" — a real risk to any bare
host-port curl check on this VM, since CSB sandboxes bind host ports
directly rather than through a mediated dispatch that would reject a
duplicate. Task 2 could not resolve this itself (its own auto-mode
permission check blocked deleting a sandbox it hadn't created). This
round attempted the fix directly:

```text
$ openshell sandbox delete tankos-openclaw
✓ Deleted sandbox tankos-openclaw
```

Succeeded outright — no permission error, no already-gone state.
Independently verified what was actually bound to host port 18789
immediately before and after, rather than trusting `openshell forward
list` alone (which only reports forwards *this task's own*
`openclaw.service` created — not a competing bind another sandbox might
hold directly via host networking):

```text
# before deletion
$ sudo ss -ltnp 2>/dev/null | grep 18789
LISTEN 0 128 127.0.0.1:18789 0.0.0.0:* users:(("ssh",pid=121465,fd=3))
# after deletion
$ sudo ss -ltnp 2>/dev/null | grep 18789
LISTEN 0 128 127.0.0.1:18789 0.0.0.0:* users:(("ssh",pid=121465,fd=3))
```

Identical before and after — same PID (`121465`), confirmed via
`openshell forward list` (`tank-csb 127.0.0.1 18789 121465 running`) to
be `openclaw.service`'s own `openshell forward` SSH tunnel into
`tank-csb`. This means `tankos-openclaw`, despite being `Ready`, was
never actually the process bound to host port 18789 at the time of this
Finding's dashboard checks above — its host-networking presence never
materialized as a literal competing bind on 18789 on this particular
VM, so the `HTTP_200` results in (c) and (d) above are confirmed to be
hitting `tank-csb`, not `tankos-openclaw`. (This is a statement about
what was actually observed on this one VM at this one time, not a
general claim that host-networked CSB sandboxes can never collide on a
shared port — Task 2's underlying concern about the mechanism stands.)
`tankos-openclaw` has now been deleted, removing this ambiguity for any
future verification round on this VM. The sandbox-internal
`sandbox exec ... curl` checks in (c)/(d) were never subject to this
ambiguity in the first place, since they address the sandbox's loopback
directly rather than the shared host port.

**Caveat 1 — the literal `/usr/libexec/tank-os` install path was not
exercised, and this is a genuine gap, not a shortcut.** This dev VM's
running bootc image predates this branch's rootfs changes, and, being an
ostree/composefs deployment, `/usr` is read-only by design — `sudo cp` into
`/usr/libexec/tank-os` fails with `Read-only file system`, and there is no
existing mountpoint file there for a new script (`bootstrap-csb-sandbox`,
`check-csb-sandbox-health`) to bind-mount over. `ostree admin unlock` would
have made the deployment mutable, but was treated as out of scope for this
task to invoke unilaterally on a shared VM (a real security-relevant
control, not a paperwork obstacle) rather than the intended lighter-weight
"patch a running VM" path Task 6 was scoped for. Verification instead
placed the actual checkout's files under the `openclaw` user's own home
directory and pointed the (already-writable, per the brief's own Step 1)
`~/.config/systemd/user/openclaw*.service` units' `ExecStart=` lines at
that location instead of `/usr/libexec/tank-os`. This exercises the real
script/unit *content* and *behavior* end to end (everything Steps 2–3
check), but not the final `/usr/libexec/tank-os` path itself, nor the
`Containerfile`/`sed`-substitution install step Task 4 changed — reinforcing
Step 4's own recommendation below that a full `make build && make
build-qcow2` cycle against a fresh VM is a warranted pre-ship check, not
just a formality.

**Caveat 2 — the literal external `ssh -L 18789:127.0.0.1:18789` tunnel and
browser check could not be independently re-run from this task's own
execution environment**, which silently rejects any `ssh` invocation using
`-L`/`-N` local port-forwarding regardless of sandbox settings (plain
remote-command `ssh` calls to the same VM worked throughout this task
without issue). This is a restriction of the agent's own execution
environment, not the VM or the design — no evidence surfaced that
`openshell forward` itself is broken; quite the opposite, curling the
VM's own `127.0.0.1:18789` (the literal bind `openshell forward` creates)
returned `200` with real dashboard content. This mirrors Open Question
6's own precedent of naming a literal check that couldn't be independently
re-verified in a given test session rather than silently skipping it: the
mechanism is proven working right up to the point the human's own browser
would attach to it, but that final hop needs a human (or an environment
that permits local port-forwarding) to close out.

**A welcome surprise:** after this task's Step 5 deleted `tank-csb` to
clean up, `openclaw-healthcheck.timer` (left enabled from Step 1)
detected the now-unreachable gateway within its normal 30s cadence and
transparently restarted `openclaw.service`, which recreated `tank-csb`
and brought it back to `Ready` on its own — an unplanned, real-world
repeat of Finding L's own deliberate kill-test, this time triggered by an
ordinary sandbox deletion rather than a killed CLI process. Separately,
`openshell sandbox delete tank-csb --force` (the exact form both this
task's brief and Finding L's own text use) now errors with `unexpected
argument '--force' found` on the CLI version installed on this VM — a
harmless CLI-surface drift (`openshell sandbox delete <NAME>...` takes no
`--force` flag in this version) worth fixing in the brief/plan text, not a
functional defect.

**Pre-ship follow-up (Task 6's Step 4):** this verification ran against a
manually-patched dev VM, not a full `make build && make build-qcow2`
image — run that heavier rebuild-and-reboot cycle once, against a fresh
VM, as a final sanity check before this ships to real users. It is the
only remaining way to exercise the actual `Containerfile`/`sed`
substitution path Task 4 changed and the real `/usr/libexec/tank-os`
install location, neither of which Caveat 1 above was able to re-verify.

**VM left clean.** Since this is a shared dev VM other work depends on,
the ad hoc `openclaw.service`/`openclaw-healthcheck.{service,timer}`
units under `~/.config/systemd/user/` and the `~/tank-os-verify` install
directory used for this verification (both artifacts of Caveat 1's
workaround, not part of the shipped design) were removed after the
checks above, and `tank-csb` was deleted a final time with the
healthcheck timer confirmed disabled first so it would not be
auto-recreated. See the Task 6 fix-round report for the full
command/output trail; `systemctl --user list-units --all`,
`openshell sandbox list`, and `ls ~` all confirm a clean baseline
afterward.

## The design

### Component roles

| Component | Role | Replaces in tank-os today |
|---|---|---|
| **CSB image** (`quay.io/redhat-et/openclaw:csb-*`) | The actual OpenClaw+OpenShell integration — policy, entrypoint, config generation (`configure-openclaw.mjs`). Consumed as-is; not modified by tank-os. | `ghcr.io/openclaw/openclaw`, tank-os's own derived `tank-claw-openshell` image (`bootc/openclaw-openshell/`), and the separately-pinned OpenShell sandbox image. |
| **OpenShell** (already installed on the tank-os host via RPM, per `docs/openshell.md`) | Sandbox creation/lifecycle, `provider`-based credential resolution, `forward`/`service expose` for dashboard reachability. | Already present in tank-os; role expands from "tool-call sandbox only" to "hosts the CSB sandbox that runs OpenClaw itself." |
| **A new tank-os boot-time bootstrap script** | A non-interactive port of what `scripts/openclaw-csb create` does interactively: registers OpenShell providers from tank-os's existing Podman-secret store (see `docs/provisioning.md`'s Podman Secrets section, including the host-SSH-pipe method added earlier in this effort), creates the CSB sandbox fresh on every boot (mirroring tank-os's existing recreate-on-boot pattern for its current tool-call sandbox — no dependency on OpenShell's `StartupResume`), and starts the dashboard forward bound to the VM guest's own loopback `18789` (Finding E). | `bootstrap-openshell-sandbox`, most of `sync-podman-secrets`, and the `openclaw.container` Quadlet's direct image reference. |
| **A rewritten Quadlet/systemd unit** | **As implemented, not as originally assumed here — see Finding L.** The `sandbox create` CLI process is not the real supervised workload (killing it leaves the sandbox and its gateway running untouched), so the unit is a `Type=oneshot, RemainAfterExit=yes` that backgrounds `sandbox create`, polls for `Ready`, then exits, with a separate `openclaw-healthcheck.timer` (30s interval) doing the actual crash/hang detection via `systemctl --user restart openclaw.service` — not systemd's built-in process supervision of a foreground `Restart=on-failure` process as this row originally assumed. | `openclaw.container`. |
| **Podman secrets for whatever CSB itself doesn't route through a provider** (gateway token, and any model keys CSB handles via `read_secret()` rather than a provider) | Matches CSB's own current mixed state (Finding G) — tank-os doesn't need to be purer than CSB is today. | `sync-podman-secrets`'s existing env-injection Quadlet drop-in generation, narrowed in scope. |
| **service-gator** | Retire for GitHub (confirmed, Finding I) and Forgejo (confirmed, Finding J). GitLab is *inferred* to behave the same as GitHub — same built-in provider type — but was never independently hands-on tested; treat it as likely-but-unverified, not confirmed. Keep it (or verify Jira the same way first) for Jira, which remains untested. Findings I/J give hands-on-verified evidence that OpenShell's `github` provider, and a hand-authored `generic` provider for Forgejo, cover the same scoped-credential need natively (tighter credential+policy bundling than service-gator's separate MCP-server/file-secret split, though `generic` needs materially more manual policy setup). | Removed for GitHub/Forgejo; likely removable for GitLab pending independent verification; kept pending for Jira. See Finding I / Finding J / Open Question 2. |

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
   /app/entrypoint.sh`), destroying/recreating rather than attempting to
   resume a stopped one. Two verified caveats on this exact command,
   both from Phase 0 Task 3 (2026-08-05):
   - The trailing `-- <command>` must be a wrapper, not the bare
     `/app/entrypoint.sh` path: without a trailing command at all, the
     sandbox comes up idle instead of running CSB's entrypoint/gateway
     (Future consideration 6); with `/app/entrypoint.sh` alone, it fails
     immediately on `OPENCLAW_GATEWAY_TOKEN is required on every
     startup` (`/run/secrets/*` is unreachable inside an OpenShell
     sandbox, Finding K). The verified working form uploads secret
     files via `--upload` and exports them in a shell wrapper before
     `exec`ing the real entrypoint — see Finding K for the exact command
     and Future consideration 5 for why the naive form doesn't work.
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
     `quay.io/redhat-et/openclaw:csb-2026.07.21`.** Use this immutable,
     date-stamped **tag** (a multi-arch manifest list — each host
     resolves its own architecture automatically), not `csb-latest` —
     CSB rebuilds on a daily schedule (see workflow's "Check upstream
     version" job), so `csb-latest` pulled on a different day could
     silently resolve to a different image than the one validated here.
     **Do not substitute the digest recorded below for the tag on a
     multi-arch host**: the digest
     (`sha256:93e5610b1f2a920d37d4ed9c09495d0b86d827c279fcabceb0768082a686c2ad`)
     is the `linux/arm64` manifest entry specifically (this spike ran on
     Apple Silicon) — pinning to it on an `amd64` host would pull the
     wrong architecture (or fail outright). The digest is recorded only
     to make this spike's exact image reproducible on the same
     architecture it was tested on; the tag is the value to use for
     general-purpose pinning. This tag was *discovered* by resolving
     `csb-latest` via a live `skopeo list-tags`/`skopeo inspect` against
     `quay.io/redhat-et/openclaw` and `podman pull`, then reading off the
     immutable tag it currently pointed to — `csb-latest` itself is not
     the recommended value.
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
2. **service-gator's fate — resolved for GitHub and Forgejo, still open
   for GitLab (inferred, not independently tested) and Jira (untested).**
   **Verified 2026-08-05 (Phase 0, Task 5 — Finding J).**
   **Recommendation: retire service-gator for GitHub (confirmed, Finding
   I) and Forgejo (confirmed, Finding J); treat GitLab as likely covered
   by the same built-in provider type as GitHub but not independently
   hands-on tested — verify before dropping service-gator for GitLab
   specifically; keep it (or plan a dedicated verification pass) for
   Jira until that's hands-on tested the same way.**
   - **GitHub**: confirmed working via the built-in `github` provider
     type (Finding I).
   - **GitLab**: **not independently tested**, in this task or Finding I.
     It's *inferred* to behave like GitHub because it's also a built-in
     provider type (per Finding A), but that inference has never been
     hands-on verified — don't conflate "likely" with "confirmed" here.
   - **Forgejo**: confirmed working via the `generic` provider type
     against a real, plain-HTTP homelab instance — but only after
     hand-authoring an endpoint policy (no CLI flag on `provider create`
     covers this for `generic`) and discovering that a `binaries`
     allowlist is mandatory per rule or the request is silently denied.
     See Finding J for the full sequence and the exact gap. This is
     meaningfully more setup than GitHub/GitLab get for free, and the
     implementation plan should budget for it (most likely by scripting
     a reusable custom provider-profile YAML per non-built-in service,
     rather than re-deriving the policy by hand each time).
   - **Jira**: **still untested** — no test Jira instance or token was
     available during this spike. Do not treat Jira as covered by the
     Forgejo result; it needs its own hands-on pass (a test instance/API
     token) before service-gator is dropped for Jira specifically.
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
   for binding the dashboard to the guest's loopback (Finding E). **Resolved
   2026-08-05 (Phase 0, Task 4) — recommendation: use `forward`.**
   Hands-on comparison against `openshell` 0.0.92 on the Task 2/3 VM, with
   the CSB gateway actually running inside `csb-spike` (see Future
   consideration 5 for how the `OPENCLAW_GATEWAY_TOKEN` blocker was worked
   around for this test only):
   - **`openshell forward start <port> <sandbox> --background`** is a
     literal TCP tunnel: the host-side bind port and the sandbox-internal
     target port must be the *same* number (confirmed empirically — a
     mismatched pair, host `28789` against a sandbox process actually
     listening on a different port, produced `curl: (52) Empty reply from
     server`; a matched pair, `28791` on both sides, worked). Verified
     end-to-end with a throwaway plain-HTTP listener inside `csb-spike`:
     `ssh -L 28791:127.0.0.1:28791` from the laptop, through
     `openshell forward`, into the sandbox's isolated network namespace,
     returned a clean `HTTP/1.1 200 OK` with the expected body. No TLS
     appears anywhere in this path — it's plain HTTP end to end (the outer
     SSH tunnel is the only encryption layer, exactly matching tank-os's
     existing documented dashboard-access pattern in `docs/cli.md`), so
     there is no secure-context/certificate-warning concern for a browser
     at all.
   - **Websocket traffic was not separately tested end to end against the
     real dashboard, and that's not a gap for either mechanism, for two
     different reasons.** For `forward`: it's a raw TCP tunnel with no
     protocol awareness (confirmed above — it moved a plain HTTP
     request/response with zero involvement at the HTTP layer), so it is
     protocol-transparent by construction; a websocket upgrade is just
     more bytes on the same already-proven TCP path, independent of
     whether this task separately drove one to completion. For
     `service expose`: the question is moot, not passed — its TLS
     handshake fails before any HTTP or websocket-upgrade negotiation
     could even begin, so there is no protocol to characterize.
   - **The literal dashboard port (18789) could not be tested directly on
     this shared spike VM**: the VM's pre-existing baseline
     `openclaw.service`/`openclaw` container (tank-os's *current*,
     pre-CSB dashboard, `quay.io/redhat-et/tank-claw-openshell:2026.7.1`)
     already binds `0.0.0.0:18789` directly via host networking, so
     `openshell forward start 18789 csb-spike` fails with "Port 18789 is
     already in use." This is an artifact of validating the old and new
     models side by side on one VM, not a design flaw — Finding C's
     ONE-sandbox model means the baseline service is retired when CSB
     takes over, so this collision would not occur in the target
     architecture. Stopping the baseline service to clear the port for
     this test was considered and explicitly not done (out of scope for a
     validation spike to disrupt a service it didn't create). Internally,
     `curl http://127.0.0.1:18789/` from inside `csb-spike` itself
     returned `200 OK`, confirming the real dashboard is alive and
     healthy — only the external-forward hop on that exact port number was
     untested, and the generic mechanism was proven working with a
     different, non-colliding port on the same sandbox above.
   - **`openshell service expose <sandbox> <port>`** does *not* bind a
     host TCP port at all — it registers hostname-based routing through
     OpenShell's own gateway control port (`17670`), returning a URL like
     `https://default--csb-spike.openshell.localhost:17670/`. This
     sidesteps the port-collision problem entirely, so it *was* tested
     directly against the real dashboard target
     (`127.0.0.1:18789` inside `csb-spike`). Result: the TLS handshake on
     that URL requires a **client certificate** (`curl -k` against it
     fails with `SSL routines::tlsv13 alert certificate required` after
     the server explicitly sends `Request CERT`). There is no
     `openshell` flag or subcommand to obtain or install a client
     certificate for an ordinary browser, and no `--insecure`-equivalent
     that disables server-side client-cert enforcement. **This is a harder
     failure than Open Question 6 anticipated** — it isn't a missing
     secure-context guarantee or a self-signed-cert warning a user could
     click through; it's a TLS handshake a stock browser cannot complete
     at all.
   - **Recommendation for the follow-up implementation plan: use
     `forward`.** It is a proven, working, plain-TCP mechanism (verified
     end to end on a substitute non-colliding port inside `csb-spike`,
     not literally re-run against port 18789 itself — see above for why)
     that preserves the existing SSH-tunnel-then-browse UX unchanged. Do
     not use `service expose` for the dashboard unless/until OpenShell
     ships a supported way to provision browser-usable client
     certificates for its hostname-routed URLs.
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

Raised after the design above was agreed; most of these don't need to be
resolved before the first implementation spike, but they should shape how
that spike and later phases are built. **Exception: item 5 below does
block Task 4 of the Phase 0 validation spike** if that task needs the
OpenClaw gateway actually serving the dashboard rather than just an idle
sandbox — see item 5 for details.

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

**RESOLVED 2026-08-05 — see Finding K above.** `--upload` plus a wrapper
shell command in the trailing `-- <COMMAND>` gets every `read_secret()`
key into CSB's environment without argv exposure, verified end to end
(gateway reached `ready`, served `200`). The original writeup below is
kept for the root-cause narrative (why `/run/secrets` itself is
unreachable, why `--env` alone isn't safe), not because the gap is still
open.

**Worked around for Task 4 of the Phase 0 spike only — not solved.**
Task 4 needed the OpenClaw gateway actually running/serving the dashboard
to test `forward` vs. `service expose` reachability (Open question 6).
Since there is still no secure way to supply `OPENCLAW_GATEWAY_TOKEN`
(see below, unchanged since Task 3), Task 4 generated a random,
throwaway token value (`openssl rand -hex 24`) used once for a single
disposable sandbox and never persisted as a Podman secret or reused
elsewhere, and passed it via `--env OPENCLAW_GATEWAY_TOKEN=<value>`. This
is explicitly a different risk class from the "never pass raw secrets via
`--credential KEY=VALUE`" constraint elsewhere in this doc, which protects
real, reused credentials (API keys) from broad host/argv exposure — it is
not a template for how the bootstrap script should handle the real
gateway token in production. With the token supplied this way, the
gateway reached `[gateway] ready` and served `200 OK` on `18789`
(evidence in Open question 6). The secure-mounting gap itself remains
exactly as described below, still flagged for the follow-up
implementation plan.

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
