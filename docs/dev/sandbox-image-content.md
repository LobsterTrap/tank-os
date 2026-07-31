# Discussion: what should the OpenShell sandbox image contain?

Status: open discussion, not a decision. No action items yet — this is meant
to seed a conversation before we commit to a direction.

## Background

tank-os runs OpenClaw's tool calls inside an OpenShell sandbox container
(see `docs/openshell.md` for the architecture). That sandbox is built from
`ghcr.io/lobstertrap/openshell-hummingbird-images/sandboxes/openclaw`, a
Hummingbird-based rebase of NVIDIA's own Ubuntu-based community sandbox
image, pinned by digest in
`bootc/rootfs/usr/libexec/tank-os/bootstrap-openshell-sandbox`.

We've never written down *why* that image contains what it contains, or
what it should contain going forward. This doc collects what we found
looking at the upstream image it's derived from, plus a few open questions
worth resolving as a group rather than unilaterally.

## Finding 1: the sandbox image is currently stale, and the fix isn't local

The pinned digest resolves to Hummingbird OS `20251124`. Checking the
`openshell-hummingbird-images` GHCR repo directly, that digest is in fact
the *newest* tag that repo has ever published — nobody has rebuilt it since
2026-05-06. So re-pinning to a different existing tag won't help; getting a
fresher base means rebuilding `openshell-hummingbird-images` upstream (or
forking it).

Separately, `quay.io/organization/hummingbird`'s individual component images
(`python`, `git`, `curl`, `jq`, `core-runtime`, etc.) are rebuilt roughly
daily — confirmed by tag timestamps at time of writing. Their `VERSION_ID`
in `/etc/os-release` staying at `20251124` even in a freshly-rebuilt image is
expected, not a bug: like RHEL/UBI minor versions, it identifies a release
line, not a build date — packages inside that line get patched without the
`VERSION_ID` label moving. Worth remembering next time image freshness looks
suspicious from `/etc/os-release` alone; check tag `last_modified` on the
registry instead.

**Option worth considering**: fork/rebuild the sandbox image ourselves
directly from the daily `quay.io/organization/hummingbird` component images,
rather than depending on `openshell-hummingbird-images`' release cadence.

## Finding 2: NVIDIA's own `base` sandbox image is a useful reference point

Source: `NVIDIA/OpenShell-Community` repo, `sandboxes/base/Dockerfile`
(the community registry `openshell-hummingbird-images/sandboxes/openclaw`
is presumably derived from this, or something like it).

It's built in three layers:

1. **System** (Ubuntu Noble base): `ca-certificates`, `curl`, `dnsutils`,
   `iproute2`, `iptables`, `nftables`, `iputils-ping`, `net-tools`,
   `netcat-openbsd`, `openssh-sftp-server`, `procps`, `traceroute`, plus
   dedicated `supervisor`/`sandbox` unprivileged users. Several of these
   (`iproute2`, `iptables`, `nftables`) exist to support OpenShell's own
   network-namespace/policy-proxy machinery, not for agent use directly.
2. **Devtools**: Node.js 22.22.1 (version-pinned, with CVE tracking in a
   comment), npm 11, `git`, `gh` (GitHub CLI), Claude CLI, and — notably —
   other coding-agent CLIs installed globally via npm: `opencode-ai`,
   `@openai/codex`, `@github/copilot`. Python is **not** an apt package; it's
   installed and version-pinned via `uv` into a writable venv at
   `/sandbox/.venv`, decoupling the Python version from whatever the base OS
   ships.
3. **Final**: policy file, a `github` skill, shell profile setup, drops to
   the unprivileged `sandbox` user.

No Bun anywhere in NVIDIA's image.

**Open question**: does the tank-os/OpenClaw sandbox need the "other agent
CLIs" capability (`opencode-ai`, `codex`, `copilot`) that NVIDIA bakes in for
their own multi-agent community use case, or is that dead weight we should
trim? Do we need Node at all if OpenClaw's own tool calls are shell/Python
focused, or does something in our expected workloads need it?

## Finding 3: the network policy, not the binary list, is the real security boundary

`sandboxes/base/policy.yaml` in the same repo shows the actual design
intent: network access is **default-deny, opt-in per (binary, endpoint)
pair**, not a flat allowed-hosts list. Each named policy (e.g. `claude_code`,
`pypi`, `github_rest_api`) pairs specific binary paths with specific
endpoints, and binary identity is verified via `/proc/{pid}/exe` inode
resolution plus SHA256 trust-on-first-use — not just a path string match.

Practical implication: installing a tool with no corresponding
`network_policies` entry gives the agent a binary that exists but can't
reach anything. That's a reasonable default-safe posture, but it means
"what's in the image" and "what's in policy.yaml" are two halves of one
decision — adding a tool without a matching policy entry is a silent no-op
for that tool's network access, not a security hole, but also not obviously
correct either way without deciding it deliberately.

Several policy entries in NVIDIA's file (`vscode`, `cursor`, `copilot`,
`codex`, `opencode`, `nvidia_inference`) look like they're there for
NVIDIA's broader community use case rather than anything tank-os currently
needs — worth pruning if we fork this file rather than inheriting it
wholesale.

## Finding 4a: the bundled agent CLIs are for a use case tank-os doesn't have

NVIDIA's own docs (`docs/about/supported-agents.mdx` in `NVIDIA/OpenShell`)
explain why `base` bundles Claude Code, Codex, Copilot, and OpenCode:

> "Agents in the base image are auto-configured when passed as the trailing
> command to `openshell sandbox create`."

i.e. `base` is meant for `openshell sandbox create --from base -- codex` —
the sandboxed process **is** one of those CLIs, chosen at launch time by
whoever creates the sandbox. It's a "pick one of several coding assistants
to run sandboxed" menu, not a toolbox for some other orchestrator to shell
out to.

tank-os never launches a sandbox that way. `bootstrap-openshell-sandbox`
pre-creates the sandbox with no trailing agent command; OpenClaw's plugin
SSHes in afterward and runs arbitrary shell commands the OpenClaw agent
decides on. None of the four bundled CLIs are ever invoked in that flow —
they're inherited baggage from forking the generic multi-agent `base`
image, not a deliberate choice for tank-os's actual usage pattern.

Worth noting: the same support-matrix table lists **OpenClaw's own
NVIDIA-recommended integration path as a separate project, NemoClaw**
(`github.com/NVIDIA/NemoClaw`) — not the `base` image tank-os forked. See
Finding 4b before assuming NemoClaw is a shortcut, though.

## Finding 4b: NemoClaw is not a drop-in leaner alternative

NemoClaw (NVIDIA's own "run OpenClaw more securely inside OpenShell"
project) looks at first glance like it might sidestep this whole question,
but it's a materially different architecture, not a leaner sandbox image:

- Built on `node:22-trixie-slim` (Debian), not Hummingbird.
- It bakes **the entire OpenClaw gateway into the sandbox image itself** —
  `npm ci`-installs OpenClaw, patches OpenClaw's own source directly
  (`patch-openclaw-tool-catalog.mts`, `patch-openclaw-chat-send.mts`,
  `patch-openclaw-mcp-npx.mts`, and others), creates both `gateway` and
  `sandbox` users, generates `openclaw.json` at build time.
- That collapses tank-os's two-container split (OpenClaw gateway container
  + separate SSHed-into sandbox container) into one combined image —
  a different topology, not a substitute component.

Adopting NemoClaw would mean replacing tank-os's container architecture
entirely, not swapping a digest. It's out of scope for the sandbox-content
question this doc is about; noted here so it doesn't get re-proposed as a
quick fix without this context.

## Connecting 4a back to Finding 3 (Hummingbird vs. CVE surface)

The tension raised in discussion — "why use a zero-CVE base and then layer
a Node/npm dependency tree on top of it" — is legitimate, but it's largely
the *same* problem as Finding 4a, not a separate one. Most of the
Node/npm footprint in the current image comes from the three redundant
agent CLIs (`opencode-ai`, `@openai/codex`, `@github/copilot`) that Finding
4a shows tank-os doesn't need. NVIDIA's own Dockerfile comments show they
don't get this for free either — they manually pin `tar@7.5.11`, upgrade
`npm` to v11, and cite specific CVE numbers for their Node layer, because
the npm ecosystem doesn't inherit Hummingbird's/UBI's provenance guarantees
just by being copied into the same image.

Practical takeaway: "zero-CVE" describes the curated OS package set, not
anything layered on top of it — that part is the integrator's
responsibility regardless of base image. Trimming the redundant agent CLIs
removes most of the current npm attack surface for free; whatever
legitimate footprint remains (git, and Node/Python only if something in
our actual workloads needs them) is small enough to actually apply the
same pin-and-scan discipline to (e.g. with `grype`, itself a Hummingbird
image).

## Finding 5: sandbox selection is static in tank-os, by design

`plugins.entries.openshell.config.from` in OpenClaw's config
(`bootstrap-openclaw`) is documented to accept only a bare sandbox *name*,
not a full image reference. NVIDIA's community flavors (`base`, `droid`,
`gemini`, `nvidia-gpu`, `ollama`, `pi`, `sdg`) are meant to be selected this
way, resolved against `ghcr.io/nvidia/openshell-community/sandboxes/{name}`.

tank-os's sandbox is a custom image referenced by full digest, which `from`
can't express directly. The workaround:
`bootstrap-openshell-sandbox` pre-creates exactly one sandbox, under the
fixed name `tankos-openclaw`, from the pinned digest, *before* OpenClaw's
gateway starts. `from: "tankos-openclaw"` then just means "the one sandbox
that already exists," resolved via `sandbox get`, never `sandbox create`.

There is currently no mechanism in this repo for offering more than one
sandbox flavor per deployment. Supporting that would mean extending
`bootstrap-openshell-sandbox` to pre-create multiple named sandboxes and
deciding, per-agent-config, which name to reference — new design work, not
something OpenShell provides out of the box.

## Related, smaller finding: `OPENSHELL_VERSION` duplication

Not sandbox-image-specific, but adjacent: `OPENSHELL_VERSION=0.0.92` is
independently hardcoded in both `bootc/Containerfile` (host RPMs) and
`bootc/openclaw-openshell/Containerfile` (CLI binary in the OpenClaw
container), with no shared source of truth. Nothing enforces they stay in
sync. Worth hoisting into the `Makefile` as a single build-arg source
regardless of what we decide about sandbox content.

## Questions for the team

1. Do we fork/rebuild the sandbox image against the daily-refreshed
   `quay.io/organization/hummingbird` component images, or push for a
   faster release cadence on `openshell-hummingbird-images` instead?
2. What's the intended scope of the sandbox — generic dev environment
   (broad toolset, since we don't know in advance what repos/languages
   agents touch) or minimal-by-default with per-deployment customization
   layered on top?
3. Do we need the "run other agent CLIs from inside the sandbox" capability
   NVIDIA's image includes, or is that out of scope for tank-os's use case?
   (Per Finding 4a: current evidence says no — nothing in tank-os's flow
   ever invokes them.)
4. If we prune `policy.yaml`, which of NVIDIA's non-OpenClaw policy entries
   (`vscode`, `cursor`, `copilot`, `codex`, `opencode`, `nvidia_inference`)
   are actually irrelevant to us, versus worth keeping for future
   flexibility?
5. Is a single fixed sandbox flavor (current state) sufficient long-term, or
   should we plan for multiple named sandboxes per deployment?
