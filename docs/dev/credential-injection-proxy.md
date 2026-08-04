# Discussion: keeping the raw LLM API key out of the OpenClaw container

Status: open discussion, not a decision. Captured ahead of conversations with
Sally (tank-os) and the Claw Operator team — no action items yet.

## Background

Today, `bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets:26-37` injects
model-provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) as plain
container env vars directly into the OpenClaw gateway container via a Quadlet
`Secret=...,type=env,target=...` drop-in. The raw key is therefore sitting in
the same process environment as the long-running LLM agent gateway.

The goal explored here is **defense-in-depth / least privilege**, not closing
a specific known exploit: a long-running, internet-facing gateway process
shouldn't need to hold a plaintext high-value credential if an equally simple
architecture can avoid it. (Tool-call execution is already isolated —
OpenClaw's tool calls run inside a separate OpenShell sandbox reached over
SSH, per `docs/openshell.md` — so this is specifically about the gateway
process's own LLM API calls, which are made directly using its own env var.)

## Finding 1: OpenShell's own credential injection is real, but sandbox-scoped

OpenShell has a first-class `provider` mechanism (see
<https://docs.nvidia.com/openshell/sandboxes/manage-providers> and
[NVIDIA/NemoClaw#1841](https://github.com/NVIDIA/NemoClaw/discussions/1841)):
a provider (`openshell provider create --type openai --credential
OPENAI_API_KEY=...`) is attached to a sandbox at creation time
(`openshell sandbox create --provider my-openai -- <cmd>`). The sandboxed
process's env only ever contains a placeholder token
(`openshell:resolve:env:OPENAI_API_KEY`, or the same literal embedded in a
header/query-param/URL-path); OpenShell's own TLS-terminating L7 proxy
rewrites the placeholder to the real value at egress, failing closed (HTTP
500) if it can't resolve it. This is generic — provider types include
`github`, `gitlab`, `copilot`, and a `generic` type, not just LLM inference
providers — so it's the same category of problem service-gator solves today,
via a different, non-OpenShell mechanism.

Checked directly against the current `~/work/forks/OpenShell` source (main,
`b9818619`) to confirm this isn't available to processes outside a sandbox:
the gRPC call that resolves real credentials, `GetInferenceBundle`, hard-fails
unless the caller presents a sandbox JWT (`Principal::Sandbox`) —
`crates/openshell-server/src/inference.rs:956,959`, enforced again in
`auth/sandbox_methods.rs:33` and `auth/method_authz.rs:143`. Sandbox JWTs are
minted only through the sandbox lifecycle/bootstrap path
(`architecture/gateway.md:191-207`). Git history shows the mechanism moving
*further* into sandbox-local routing over time
(`31d7ca53`/`1ca23bc5`, 2026-03-06), not toward a decoupled/standalone mode.
There is no `openshell secret`/standalone credential-proxy CLI surface
(`.agents/skills/openshell-cli/cli-reference.md:38-101`).

**Implication for tank-os:**

- **Tool-call credentials** (the GitHub/GitLab/Forgejo/Jira tokens
  service-gator handles today, per `docs/service-gator.md`) are a genuine
  zero-topology-change fit: tool calls already execute inside the OpenShell
  sandbox `bootstrap-openshell-sandbox` creates. Attaching providers to that
  sandbox could replace or complement service-gator's separate
  MCP-server/file-secret approach.
- **OpenClaw's own LLM key** does not fit today's topology: OpenClaw's
  gateway process (the thing actually calling `api.openai.com`) runs outside
  the sandbox; only its tool calls go through SSH into it. Using the
  `provider` mechanism natively for this credential would require moving
  OpenClaw itself inside a sandbox — the same pattern NemoClaw's own
  `openclaw-nvidia` reference variant uses. See Finding 2 for why that's a
  bigger decision than it looks.

## Finding 2: moving OpenClaw inside a sandbox costs real operational guarantees

Investigated whether OpenShell's sandbox model can host a long-running,
auto-restarting, LAN-reachable service the way `openclaw.service`'s Quadlet
unit does today (`bootc/rootfs/etc/containers/systemd/users/1000/openclaw.container:22-26`,
`Restart=on-failure`, `WantedBy=default.target`, port 18789 bound directly).

- **No reboot survival for rootless Podman sandboxes.** OpenShell's
  `StartupResume` reconciliation (restarting sandbox containers after a
  gateway/daemon restart) is implemented only for the Docker compute driver —
  `crates/openshell-server/src/compute/mod.rs:1574`, confirmed by
  `new_podman()` passing `None, None, None` for resume hooks at
  `compute/mod.rs:796-820` vs. the Docker path wiring `Arc<dyn
  StartupResume>` at `compute/mod.rs:728-731`. A rebooted host would not
  bring the sandbox back the way `WantedBy=default.target` does today.
- **No crash supervision in the reference pattern.** The
  `openclaw-nvidia`/`openclaw` sandbox variants in
  `~/work/repos/LobsterTrap/openshell-hummingbird-images` run the gateway via
  bare `nohup openclaw gateway > /tmp/gateway.log 2>&1 &`
  (`sandboxes/openclaw-nvidia/openclaw-nvidia-start.sh:123`,
  `sandboxes/openclaw/openclaw-start.sh:8`) — no supervisor, no equivalent of
  `Restart=on-failure`.
- **No direct port publish.** `openshell forward` (`crates/openshell-cli/src/main.rs:1403-1406`)
  is a client-side SSH tunnel process tracked by PID file
  (`crates/openshell-core/src/forward.rs:20-47`) with no auto-restart if it
  dies; `openshell service expose` instead routes via gateway
  hostname-based routing (`openshell.localhost`-style,
  `manage-sandboxes.mdx:245-289`), not a fixed `host:18789` TCP bind.

**Conclusion:** adopting the sandbox topology to get native `provider`
injection for OpenClaw's own key would mean tank-os re-implementing
systemd-level supervision (crash restart, reboot survival, LAN port
exposure) on top of OpenShell, essentially to relocate where one credential
lives. Not impossible, but a materially bigger project than it first
appears.

## Finding 3: claw-operator-upstream already built a portable version of "hold the key in a sidecar proxy"

`~/work/forks/claw-operator-upstream` (the Claw Operator, for OpenShift/K8s
OpenClaw deployments) solves the identical problem — OpenClaw should never
hold the real provider key — with a standalone, well-tested Go proxy.

**Where it lives:** `cmd/proxy/main.go` + `internal/proxy/` (`server.go`,
`config.go`, `injector.go`, and one file per injector strategy —
`injector_apikey.go`, `injector_bearer.go`, `injector_gcp.go`,
`injector_kubernetes.go`, `injector_oauth2.go`, `injector_pathtoken.go`,
`injector_none.go`, `body_rewriter.go`), ~3,700 lines including tests
(`server_test.go` 858 lines, `config_test.go` 526, `injector_test.go` 454).
Built via `Containerfile.proxy` into a distroless image, `make build-proxy` /
`make container-build-proxy`.

**How it works:** two modes. A `goproxy`-based MITM forward proxy
(`server.go:34,65,88-91`) — OpenClaw gets `HTTP_PROXY`/`HTTPS_PROXY` env vars
plus CA-trust env vars (`NODE_EXTRA_CA_CERTS`, etc.) pointing at a
per-instance CA the proxy signs with, so any provider's real hostname works
unmodified, no `baseUrl` override needed. And a simpler
`httputil.ReverseProxy`-based "gateway mode" (`server.go:29,182-197`) with
path-prefix routing (e.g. `/openai/...` → `https://api.openai.com`) for SDKs
that hardcode a base URL — closer to the `baseUrl`-override shape we'd
sketched for tank-os.

**Credential handling:** real secrets are mounted only into the *proxy's*
deployment (`internal/controller/claw_proxy.go:508-647`), read via
`os.Getenv`/file by the injector (`injector_apikey.go:49`,
`injector_bearer.go:43`). OpenClaw's own config gets a hardcoded placeholder
literal and the *real* provider `baseUrl` (`claw_resource_controller.go:1262-1323`,
placeholder at lines 1290/1295/1312) — traffic is transparently intercepted
via the forced proxy env vars.

**Routing/provider mapping:** a JSON config
(`internal/proxy/config.go:29-50`) with one `Route` per domain, an injector
type, and injector-specific fields. Provider-to-header defaults are
centralized in `internal/controller/claw_providers.go:87-166` (Anthropic →
`x-api-key`, OpenAI → `Bearer`, etc.). All requests get
`Authorization`/`X-Api-Key`/`X-Goog-Api-Key` headers stripped first
regardless of route as defense in depth (`injector.go:32-54`); unmatched
domains/paths get 403.

**What's Kubernetes-specific (would not translate directly):**

- Reaching the proxy via cluster **Service DNS** (`http://<instance>-proxy:8080`)
  rather than a fixed local address.
- **NetworkPolicy** enforcing "OpenClaw can only reach the proxy" — a
  CNI/K8s primitive with no rootless-Podman equivalent without separate
  netns/firewall work.
- CA distribution via a K8s **Secret + volume mount**, with cert lifecycle
  tied to owner references / garbage collection
  (`claw_credentials.go:733-828`).
- **Reconciliation-driven config regeneration** (server-side apply,
  pod-annotation stamping on secret rotation) — replaces what a
  `sync-podman-secrets`-style script + `systemctl restart` already does for
  tank-os.
- The optional `kubernetes` injector type (kubeconfig → per-host bearer
  tokens) is irrelevant to the LLM-key use case specifically.

**What's portable:** the `goproxy` MITM engine, the JSON route/injector
config format, and the injector implementations themselves have no
Kubernetes API dependency (aside from the optional `kubernetes` injector
type) — this is plain Go that should run under a systemd Quadlet nearly
as-is, fed by a config file a small tank-os-side script generates instead of
the operator's reconciler.

## Proposal worth discussing: one shared proxy, two deployment wrappers

Rather than tank-os reimplementing this from scratch (the standalone-proxy
option floated earlier in this discussion) or reinventing systemd
supervision inside an OpenShell sandbox (Finding 2), the shape that seems to
fit best is: extract/vendor `internal/proxy/` as a shared, deployment-agnostic
component. Claw Operator keeps its K8s-specific reconciler/manifests; tank-os
adds a Quadlet unit plus a small script (parallel to `sync-podman-secrets`)
that renders the same JSON route config and mounts the real key as a file
secret, matching service-gator's existing pattern
(`docs/service-gator.md:52-72`) rather than the current env-var injection.

This wasn't attempted or validated yet — it's the option this doc exists to
put in front of both teams.

## Open questions for the Sally / Claw Operator conversations

1. Is claw-operator-upstream's team open to `internal/proxy/` being
   consumed/vendored outside the operator (e.g. as its own Go module or
   published image), or would that require restructuring it out of the
   operator's module first?
2. If we go this route, does tank-os need the MITM forward-proxy mode (no
   `baseUrl` overrides, works for arbitrary providers) or is "gateway mode"
   (`baseUrl` override, one route per configured provider) sufficient given
   tank-os only needs to support the providers `sync-podman-secrets` already
   lists?
3. Independent of the above: does it make sense to adopt OpenShell
   `provider`s for the tool-call-side credentials (GitHub/GitLab/Forgejo/Jira)
   now, replacing or complementing service-gator, since that needs no
   topology change and no new component?
4. Is the OpenClaw-inside-a-sandbox topology change (Finding 2) worth
   revisiting later regardless, e.g. if OpenShell's Podman driver eventually
   gains `StartupResume`, or if tank-os's own reliability requirements turn
   out to tolerate a lighter-weight restart story than a Quadlet unit
   provides?

## Options on the table (not decided)

- **A — Standalone proxy, built from scratch.** Smallest blast radius, but
  duplicates work Claw Operator has already done and tested.
- **B — Standalone proxy, sharing claw-operator's `internal/proxy/` core.**
  Same operational shape as A for tank-os, but avoids reinventing injector
  logic/tests; requires coordination with the Claw Operator team on
  extracting a shared component.
- **C — Move OpenClaw inside an OpenShell sandbox**, using `provider`s
  natively. Fully adopts OpenShell's intended model for this credential, at
  the cost of hand-rolling restart/reboot/port-exposure scaffolding tank-os
  currently gets for free from systemd (Finding 2).
- **D — OpenShell `provider`s for tool-call credentials only, defer the
  OpenClaw LLM-key question.** Zero-topology-change win now (replaces
  service-gator's scope), decoupled from whichever of A/B/C gets picked
  later for the LLM key itself.

(A, B, and D are not mutually exclusive with each other; C is exclusive with
A/B for the LLM-key credential specifically.)
