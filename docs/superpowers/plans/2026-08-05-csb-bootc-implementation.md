# CSB Bootc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace tank-os's own OpenClaw+OpenShell integration with
redhat-et/openclaw-csb's published image running inside a single OpenShell
sandbox, per `docs/dev/csb-bootc-deployment-design.md`'s "The design"
section — validated hands-on in PR #40 (Phase 0 spike), PR #42 (gateway
token fix), and PR #43 (multi-secret/provider combination).

**Architecture:** A new boot-time script (`bootstrap-csb-sandbox`)
registers OpenShell providers and stages non-provider secrets, then
recreates a single named OpenShell sandbox running CSB's image on every
start. A plain systemd `--user` unit (not a Podman Quadlet — CSB's image
runs via `openshell sandbox create`, never `podman run` directly) replaces
`openclaw.container`. `sync-podman-secrets` narrows to service-gator's
existing job only; the old two-tier "OpenClaw container + separate
tool-call sandbox" scripts and tank-os's own derived image are retired.

**Tech Stack:** Bash (`set -euo pipefail`), systemd user units, Podman
secrets, the `openshell` CLI, Fedora bootc.

## Global Constraints

- **CSB image tag:** `quay.io/redhat-et/openclaw:csb-2026.07.21` (verified
  2026-08-05 against `redhat-et/openclaw-csb`'s registry and CI — see
  design doc Open Question 1). CSB rebuilds daily; **before starting Task
  1, re-run `skopeo inspect docker://quay.io/redhat-et/openclaw:csb-latest`
  and confirm this tag still resolves** (or substitute whatever newer
  date-stamped tag it now points to, updating this constant everywhere it
  appears in this plan). Never use `csb-latest` directly — it's a moving
  target.
- **Fixed sandbox name:** `tank-csb` (replaces the retired `tankos-openclaw`
  tool-sandbox name — the role is fundamentally different now: OpenClaw
  itself runs inside this sandbox, per Finding C's one-sandbox model, not a
  separate tool-call sandbox a host-side OpenClaw container connects to).
- **Podman secret names never change from what's documented today**
  (`docs/provisioning.md`): `openclaw_gateway_token`, `anthropic_api_key`,
  `openai_api_key`, `gemini_api_key`, `google_api_key`. New secrets this
  plan adds: `xai_api_key`, `mistral_api_key`, `cohere_api_key` (CSB
  supports these, tank-os didn't before). `gh_token` is reused read-only
  from service-gator's existing secret for the new GitHub provider — do
  not rename or duplicate it.
- **Never pass a real secret value via `--credential KEY=VALUE` or
  `--env KEY=VALUE`.** Both put the raw value in this process's argv,
  visible to any local user via `ps`/`/proc/<pid>/cmdline`. Always use
  `--from-existing` (provider path, Finding I) or `--upload` plus a shell
  wrapper's `export`/`rm` (Finding K path). This is the design doc's core
  security constraint and binds every task that touches a secret.
- **`export VAR="$(cmd)"` under `set -euo pipefail` does NOT abort on
  failure** — `export`/`local`/`declare` mask a command substitution's
  exit status (Open Question 7's bash gotcha; confirmed hands-on: `export
  FOO="$(false)"` exits 0 with `FOO` empty). Every script in this plan
  captures into a plain variable with an explicit `|| exit 1` first, never
  combining `export` directly with a command substitution that must be
  checked.
- **Out of scope, do not touch:** `service-gator.container`,
  `bootstrap-service-gator`, and the `gh_token`/`gitlab_token`/
  `forgejo_token`/`jira_api_token` service-gator wiring in
  `sync-podman-secrets` — service-gator retirement for GitHub/Forgejo and
  GitLab/Jira verification are deferred to a separate follow-up plan (the
  team explicitly decided on 2026-08-05 to defer further hands-on
  verification of GitLab/Jira). The only exception: Task 1 reads the
  existing `gh_token` secret (read-only) to register a new OpenShell
  `github` provider for OpenClaw's own use — this does not modify or
  remove service-gator's use of that same secret.
- **`telegram_bot_token`, `openrouter_api_key`, `model_endpoint_api_key`
  have no CSB equivalent** and are a known, accepted capability reduction
  for this pivot (design doc Open Question 3) — do not try to preserve
  them; Task 5 documents the removal.
- **Credential hygiene:** all hands-on verification runs against a real
  tank-os VM over SSH, the same way Phase 0 did. Never paste a real secret
  value into agent/subagent context — the user materializes real
  credentials themselves via `printf '%s' "$VALUE" | ssh openclaw@<vm-ip>
  "podman secret create <name> -"`. Throwaway test values (`openssl rand
  -hex ...`) may be generated directly on the VM.
- **Explicitly deferred, not silently dropped:** design doc Future
  Considerations 2 (a version-check helper), 3 (centralized sandbox policy
  management), and 4 (OpenShift Virtualization parity) are all
  self-described in the doc as non-blocking/later-phase — none of them
  have a task in this plan, matching the doc's own framing, not an
  oversight.
- **CSB's own `read_secret()` call list** (confirmed against
  `redhat-et/openclaw-csb`'s `csb/entrypoint.sh`, 2026-08-05):
  `OPENCLAW_GATEWAY_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
  `GOOGLE_API_KEY`, `XAI_API_KEY`, `MISTRAL_API_KEY`, `COHERE_API_KEY`.
  Only the env var names matter to this plan's `--upload` mechanism — the
  secret-file *names* that function reads from `/run/secrets/*` are
  irrelevant here, since `/run` is unreachable inside an OpenShell sandbox
  anyway (Finding K) and this plan never populates it.

---

### Task 1: `bootstrap-csb-sandbox` — provider registration, secret staging, sandbox lifecycle

**Files:**
- Create: `bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox`

**Interfaces:**
- Consumes: Podman secrets named per Global Constraints; the `openshell`
  CLI (`provider get/create/update`, `sandbox delete/create`); a
  `CSB_IMAGE_TAG` env var, falling back to a build-time-substituted
  `__CSB_IMAGE_TAG_DEFAULT__` placeholder (same pattern
  `bootstrap-openshell-sandbox` used for `OPENCLAW_OPENSHELL_IMAGE`).
- Produces: on success, this script's own process is replaced (`exec`) by
  `openshell sandbox create ... -- sh -c '...'` — Task 2's systemd unit
  depends on this exact behavior (the process it launches via `ExecStart`
  becomes the real workload, not a detached child).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Replaces bootstrap-openshell-sandbox and bootstrap-openclaw's job for the
# CSB-based architecture (see docs/dev/csb-bootc-deployment-design.md's
# "The design" section). Runs as the ExecStart of openclaw.service (a plain
# systemd --user unit, not a Podman Quadlet -- CSB's own image is run via
# `openshell sandbox create`, not `podman run` directly).
#
# Four jobs, all idempotent except the sandbox itself (recreated fresh on
# every start -- Open Question 7's "no dependency on StartupResume"):
#   1. Auto-provision the gateway token as a Podman secret on first boot,
#      mirroring bootstrap-openclaw's old self-service UX.
#   2. Register/update OpenShell providers for whichever of CSB's
#      provider-routed credentials (openai, github) tank-os has a secret
#      for (Finding I).
#   3. Stage whichever of CSB's read_secret()-routed keys (Finding G/K)
#      tank-os has a secret for, via --upload + a shell-wrapper trailing
#      command -- never via --env/--credential with a literal value.
#   4. Delete any sandbox left over from a prior start, then exec the real
#      `openshell sandbox create` invocation as this script's own process.

csb_image="${CSB_IMAGE_TAG:-__CSB_IMAGE_TAG_DEFAULT__}"
sandbox_name="tank-csb"

secret_exists() {
  podman secret inspect "$1" >/dev/null 2>&1
}

# Never `export VAR="$(cmd)"` directly -- under `set -euo pipefail`,
# export/local/declare mask the command substitution's exit status.
# Capture into a plain variable with an explicit check first, every time.
read_secret_value() {
  local name="$1" value
  value="$(podman secret inspect --showsecret --format '{{.SecretData}}' "$name")" || exit 1
  printf '%s' "$value"
}

# --- 1. Auto-provision the gateway token -----------------------------------

if ! secret_exists openclaw_gateway_token; then
  openssl rand -hex 32 | podman secret create openclaw_gateway_token -
fi

# --- 2. Provider registration (Finding I, Open Question 7) -----------------

register_provider() {
  local name="$1" type="$2" env_var="$3" secret_name="$4"
  secret_exists "$secret_name" || return 0
  export "$env_var"="$(read_secret_value "$secret_name")"
  if openshell provider get "$name" >/dev/null 2>&1; then
    openshell provider update "$name" --from-existing
  else
    openshell provider create --name "$name" --type "$type" --from-existing
  fi
  unset "$env_var"
}

register_provider openai-claw openai OPENAI_API_KEY openai_api_key
register_provider github-claw github GH_TOKEN gh_token

provider_args=()
openshell provider get openai-claw >/dev/null 2>&1 && provider_args+=(--provider openai-claw)
openshell provider get github-claw >/dev/null 2>&1 && provider_args+=(--provider github-claw)

# --- 3. Stage non-provider-routed secrets for --upload (Finding K) ---------

upload_dir="$(mktemp -d)"
trap 'rm -rf "$upload_dir"' EXIT
upload_args=()
wrapper_lines=()

stage_secret() {
  local secret_name="$1" env_var="$2" required="$3" f
  if ! secret_exists "$secret_name"; then
    if [[ "$required" == "required" ]]; then
      echo "bootstrap-csb-sandbox: required secret '$secret_name' not found" >&2
      exit 1
    fi
    return 0
  fi
  f="$upload_dir/$env_var"
  ( umask 077; read_secret_value "$secret_name" > "$f" )
  upload_args+=(--upload "$f:/tmp/$env_var")
  wrapper_lines+=("export $env_var=\"\$(cat /tmp/$env_var)\"; rm -f /tmp/$env_var;")
}

stage_secret openclaw_gateway_token OPENCLAW_GATEWAY_TOKEN required
stage_secret anthropic_api_key      ANTHROPIC_API_KEY      optional
if secret_exists gemini_api_key; then
  stage_secret gemini_api_key GOOGLE_API_KEY optional
elif secret_exists google_api_key; then
  stage_secret google_api_key GOOGLE_API_KEY optional
fi
stage_secret xai_api_key     XAI_API_KEY     optional
stage_secret mistral_api_key MISTRAL_API_KEY optional
stage_secret cohere_api_key  COHERE_API_KEY  optional

wrapper="$(printf '%s ' "${wrapper_lines[@]}")exec /app/entrypoint.sh"

# --- 4. Recreate the sandbox fresh every start, then exec into it ----------

openshell sandbox delete "$sandbox_name" --force >/dev/null 2>&1 || true

exec openshell sandbox create \
  --from "$csb_image" \
  --name "$sandbox_name" \
  "${provider_args[@]}" \
  "${upload_args[@]}" \
  -- sh -c "$wrapper"
```

- [ ] **Step 2: Static-check the script**

Run: `chmod +x bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox &&
shellcheck bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox`

Expected: no errors. If shellcheck flags the `wrapper_lines+=(...)` quoting
or the `provider_args`/`upload_args` array expansion, fix in place — don't
suppress the warning unless you've confirmed by hand it's a false
positive.

- [ ] **Step 3: Hands-on dry run against the tank-os VM**

Copy the script to the VM and run it manually as the `openclaw` user
(reuse the VM from Phase 0, or a fresh one — either way it needs
`openshell-gateway.service` already active). Create one throwaway secret
first so the "required" path is exercised honestly:

```bash
scp bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox openclaw@<vm-ip>:/tmp/
ssh openclaw@<vm-ip> "chmod +x /tmp/bootstrap-csb-sandbox && CSB_IMAGE_TAG=quay.io/redhat-et/openclaw:csb-2026.07.21 /tmp/bootstrap-csb-sandbox &
sleep 15
openshell sandbox get tank-csb
openshell sandbox exec -n tank-csb --no-tty -- curl -s -o /dev/null -w 'HTTP_%{http_code}\n' http://127.0.0.1:18789/"
```

Expected: `tank-csb` reaches `Ready`, curl returns `HTTP_200`. This
re-exercises Finding K's already-verified mechanism through the new
script rather than a hand-typed command — the point is to catch bugs in
the script's own plumbing (array construction, quoting, the `--from
${csb_image}` value), not to re-litigate the underlying mechanism.

- [ ] **Step 4: Clean up and commit**

```bash
ssh openclaw@<vm-ip> "openshell sandbox delete tank-csb --force; rm -f /tmp/bootstrap-csb-sandbox"
git add bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox
git commit -s -m "feat: add bootstrap-csb-sandbox for the CSB one-sandbox architecture"
```

---

### Task 2: Systemd unit replacing `openclaw.container`, with validated supervision

**Files:**
- Delete: `bootc/rootfs/etc/containers/systemd/users/1000/openclaw.container`
- Create: `bootc/rootfs/usr/lib/systemd/user/openclaw.service`
- Create (only if Step 1's test selects Variant B — see below):
  `bootc/rootfs/usr/libexec/tank-os/check-csb-sandbox-health`,
  `bootc/rootfs/usr/lib/systemd/user/openclaw-healthcheck.service`,
  `bootc/rootfs/usr/lib/systemd/user/openclaw-healthcheck.timer`

**Interfaces:**
- Consumes: `bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox` (Task 1).
- Produces: the enabled/running unit name `openclaw.service`, which Task 4
  and Task 6 both reference by that name.

The design doc's stated intent (Component Roles table) is that this
unit's `ExecStart` process IS the real supervised workload — but Phase 0
never actually tested what happens when that process is killed. This
task's first step settles that empirically before locking in the unit
shape, because the two possible outcomes need different unit files
(written out completely below — pick whichever Step 1 confirms, don't
guess).

- [ ] **Step 1: Determine whether killing the foreground CLI process tears down the sandbox**

On the VM, with `openshell-gateway.service` active, run Task 1's script
manually to bring up `tank-csb` (same as Task 1 Step 3), then:

```bash
ssh openclaw@<vm-ip> bash -s <<'EOF'
pgrep -af "sandbox create.*tank-csb"
EOF
```

Note the PID, then kill exactly that process (not the SSH session — a
clean `kill`, not a connection drop, so the result reflects what
`systemctl stop`/a real crash would do):

```bash
ssh openclaw@<vm-ip> "kill <pid>"
sleep 3
ssh openclaw@<vm-ip> "openshell sandbox get tank-csb; openshell sandbox exec -n tank-csb --no-tty -- curl -s -o /dev/null -w 'HTTP_%{http_code}\n' http://127.0.0.1:18789/ 2>&1"
```

- **If the sandbox is gone or the gateway is now unreachable:** the CLI
  process is the real supervised workload. Use **Variant A** below.
- **If `sandbox get` still shows `Ready` and curl still returns `200`:**
  the CLI's foreground attachment is cosmetic (a log-follow, not the
  supervised process) — killing it doesn't affect the actual sandboxed
  gateway. Use **Variant B** below.

Clean up before continuing: `ssh openclaw@<vm-ip> "openshell sandbox delete tank-csb --force"`.

- [ ] **Step 2a (Variant A only): write the direct-supervision unit**

```ini
[Unit]
Description=OpenClaw gateway inside a CSB OpenShell sandbox
After=openshell-gateway.service
Wants=openshell-gateway.service

[Service]
Type=simple
ExecStart=/usr/libexec/tank-os/bootstrap-csb-sandbox
ExecStartPost=-/usr/bin/openshell forward start 18789 tank-csb --background
TimeoutStartSec=900
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

(`ExecStartPost`'s leading `-` tells systemd to ignore that command's exit
status — a dashboard-forward hiccup shouldn't fail the whole unit; the
gateway itself is still up either way.)

- [ ] **Step 2b (Variant B only): write the create-then-poll unit plus a health-check timer**

Modify Task 1's script (make a copy for this variant, or adjust it
directly — Step 1 above determines which variant ships, not both): remove
the final `exec` line and replace it with a backgrounded create plus a
poll loop, since nothing needs to stay attached to the CLI's own
foreground stream:

```bash
# Replaces the final "exec openshell sandbox create ..." block from Task 1:
timeout 600 openshell sandbox create \
  --from "$csb_image" \
  --name "$sandbox_name" \
  "${provider_args[@]}" \
  "${upload_args[@]}" \
  --no-tty \
  -- sh -c "$wrapper" >/dev/null 2>&1 &
create_pid=$!

ready=false
for _ in $(seq 1 120); do
  if openshell sandbox get "$sandbox_name" 2>/dev/null | grep -q Ready; then
    ready=true
    break
  fi
  sleep 5
done

kill "$create_pid" 2>/dev/null || true

if [[ "$ready" != true ]]; then
  echo "bootstrap-csb-sandbox: $sandbox_name did not reach Ready within 600s" >&2
  exit 1
fi
```

```ini
# bootc/rootfs/usr/lib/systemd/user/openclaw.service
[Unit]
Description=OpenClaw gateway inside a CSB OpenShell sandbox (create-only; see openclaw-healthcheck.timer for supervision)
After=openshell-gateway.service
Wants=openshell-gateway.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/tank-os/bootstrap-csb-sandbox
ExecStartPost=-/usr/bin/openshell forward start 18789 tank-csb --background
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

```bash
#!/usr/bin/env bash
# bootc/rootfs/usr/libexec/tank-os/check-csb-sandbox-health
set -euo pipefail
if ! curl -sf -o /dev/null http://127.0.0.1:18789/; then
  echo "check-csb-sandbox-health: gateway unreachable, restarting openclaw.service" >&2
  systemctl --user restart openclaw.service
fi
```

```ini
# bootc/rootfs/usr/lib/systemd/user/openclaw-healthcheck.service
[Unit]
Description=Restart the CSB sandbox if its gateway stops responding

[Service]
Type=oneshot
ExecStart=/usr/libexec/tank-os/check-csb-sandbox-health
```

```ini
# bootc/rootfs/usr/lib/systemd/user/openclaw-healthcheck.timer
[Unit]
Description=Periodically verify the CSB sandbox's gateway is healthy

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Record the finding in the design doc**

Add a short "Finding L" to `docs/dev/csb-bootc-deployment-design.md`
(after Finding K) stating which variant Step 1 confirmed and the exact
kill-test evidence (PID killed, `sandbox get`/curl output before and
after) — this is exactly the kind of hands-on architectural fact the doc
already tracks (Findings A–K), and the next reader needs to know why the
unit is shaped the way it is instead of the simpler form the original
design text assumed.

- [ ] **Step 4: Delete the old Quadlet and commit**

```bash
git rm bootc/rootfs/etc/containers/systemd/users/1000/openclaw.container
git add bootc/rootfs/usr/lib/systemd/user/openclaw.service \
  docs/dev/csb-bootc-deployment-design.md
# plus the healthcheck files from Step 2b, if Variant B
git commit -s -m "feat: replace openclaw.container Quadlet with a plain CSB sandbox unit"
```

---

### Task 3: Narrow `sync-podman-secrets` to service-gator only

**Files:**
- Modify: `bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets`

**Interfaces:**
- Consumes: nothing new.
- Produces: same file, same entry point (`tank-openclaw-secrets` still
  execs it unchanged) — only its internal scope shrinks. Downstream
  behavior for service-gator's secrets must be byte-for-byte identical to
  today.

`openclaw.container`, `openclaw.json`, and the Quadlet drop-in this script
used to generate for them are all gone as of Task 2 — CSB generates its
own config, and Task 1's script builds provider/upload arguments directly
at process start instead of through a static `EnvironmentFile`. This
task deletes the now-dead half of the script and keeps the
service-gator half untouched.

- [ ] **Step 1: Remove the OpenClaw-specific block**

Delete these pieces from `sync-podman-secrets`, keeping everything about
`service_gator_dropin`/`add_service_gator_secret` exactly as-is:
- the `quadlet_dropin_dir`/`quadlet_dropin`/`config_file` variable
  declarations
- the `openclaw_secret_lines`/`add_openclaw_secret` function and its eight
  `add_openclaw_secret` calls
- the block that writes `$quadlet_dropin`
- the entire `python3 - "$config_file" ...` heredoc (the `openclaw.json`
  provider/model patching logic)
- the `mkdir -p "$quadlet_dropin_dir" ...` call's `"$quadlet_dropin_dir"
  "$HOME/.openclaw"` arguments (keep `mkdir -p
  "$service_gator_dropin_dir"`)
- update the trailing `cat <<EOF` summary to drop the `$quadlet_dropin`
  line and the "Detected OpenClaw secrets" count, and drop the
  `systemctl --user restart openclaw.service` suggestion (nothing in this
  script writes anything `openclaw.service` reads anymore)

The resulting file should be roughly a third of its current size,
containing only: `secret_exists`, the service-gator dropin-dir/file
variables, `add_service_gator_secret` and its four calls, the
`service_gator_dropin` write block, `systemctl --user daemon-reload`, and
a summary that only mentions service-gator.

- [ ] **Step 2: Static-check and verify no leftover references**

```bash
shellcheck bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets
grep -n "openclaw" bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets
```

Expected: shellcheck clean; the `grep` should only match
`service-gator`-adjacent lines incidentally containing "openclaw" (e.g. a
comment), not any `openclaw.container`/`openclaw.json`/quadlet reference.
If it does, Step 1 missed something.

- [ ] **Step 3: Hands-on confirm service-gator behavior is unchanged**

```bash
ssh openclaw@<vm-ip> "tank-openclaw-secrets"
ssh openclaw@<vm-ip> "cat ~/.config/containers/systemd/service-gator.container.d/10-secrets.conf"
ssh openclaw@<vm-ip> "ls ~/.config/containers/systemd/openclaw.container.d/ 2>&1"
```

Expected: the service-gator drop-in still lists whichever of
`gh_token`/`gitlab_token`/`forgejo_token`/`jira_api_token` secrets exist
on that VM (same as before this change); the `openclaw.container.d`
directory should now report "No such file or directory" (nothing creates
it anymore) or, if it's a leftover from before this change, contain no
newly-written file.

- [ ] **Step 4: Commit**

```bash
git add bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets
git commit -s -m "refactor: narrow sync-podman-secrets to service-gator only"
```

---

### Task 4: Containerfile, Makefile, and old-script cleanup

**Files:**
- Delete: `bootc/openclaw-openshell/` (entire directory)
- Delete: `bootc/rootfs/usr/libexec/tank-os/bootstrap-openshell-sandbox`
- Delete: `bootc/rootfs/usr/libexec/tank-os/bootstrap-openclaw`
- Modify: `bootc/Containerfile`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Task 1's `bootstrap-csb-sandbox` (needs its
  `__CSB_IMAGE_TAG_DEFAULT__` placeholder rewritten at build time, same
  pattern the old `sed` step used).
- Produces: a buildable `bootc/Containerfile` with no reference to the
  retired derived image.

- [ ] **Step 1: Remove the derived-image build args and its `sed` rewrites**

In `bootc/Containerfile`, replace:

```dockerfile
ARG OPENCLAW_REF=2026.7.1

# The OpenClaw container image, with the openshell CLI and an SSH client
# layered on top (see bootc/openclaw-openshell/Containerfile). Published to
# quay.io/redhat-et/tank-claw-openshell via `make build-openclaw-openshell
# push-openclaw-openshell` (build/push that BEFORE building this image).
ARG OPENCLAW_OPENSHELL_IMAGE=quay.io/redhat-et/tank-claw-openshell:2026.7.1
```

with:

```dockerfile
# Pinned, date-stamped CSB tag -- see
# docs/dev/csb-bootc-deployment-design.md Open Question 1. CSB rebuilds
# daily; do not use csb-latest here.
ARG CSB_IMAGE_TAG=quay.io/redhat-et/openclaw:csb-2026.07.21
```

Replace the two `sed -i` lines:

```dockerfile
    sed -i "s|Image=ghcr.io/openclaw/openclaw:.*|Image=${OPENCLAW_OPENSHELL_IMAGE}|" \
      /etc/containers/systemd/users/1000/openclaw.container; \
    sed -i "s|__OPENCLAW_OPENSHELL_IMAGE_DEFAULT__|${OPENCLAW_OPENSHELL_IMAGE}|" \
      /usr/libexec/tank-os/bootstrap-openshell-sandbox; \
```

with:

```dockerfile
    sed -i "s|__CSB_IMAGE_TAG_DEFAULT__|${CSB_IMAGE_TAG}|" \
      /usr/libexec/tank-os/bootstrap-csb-sandbox; \
```

In the `chmod 0755` list, remove
`/usr/libexec/tank-os/bootstrap-openclaw` and
`/usr/libexec/tank-os/bootstrap-openshell-sandbox`, add
`/usr/libexec/tank-os/bootstrap-csb-sandbox` (and
`/usr/libexec/tank-os/check-csb-sandbox-health` if Task 2 used Variant B).

Leave `ARG OPENSHELL_VERSION=0.0.92` and the `dnf install` of the
`openshell`/`openshell-gateway` RPMs untouched — the `openshell` CLI and
gateway still run on the VM host itself; only the derived-image build arg
is retired.

- [ ] **Step 2: Delete the retired files**

```bash
git rm -r bootc/openclaw-openshell
git rm bootc/rootfs/usr/libexec/tank-os/bootstrap-openshell-sandbox
git rm bootc/rootfs/usr/libexec/tank-os/bootstrap-openclaw
```

- [ ] **Step 3: Remove the derived-image Makefile targets**

Delete the `build-openclaw-openshell` and `push-openclaw-openshell`
targets (and their `.PHONY` lines) from `Makefile`, the corresponding
`help` lines (`build-openclaw-openshell  Build the derived...`,
`push-openclaw-openshell   Push it...`), and the `IMAGE_OPENCLAW_OPENSHELL_URI`
variable and its `help` echo line. Update `build`'s own guard clause
(the one warning "openclaw.container references this image by tag") to
reference `CSB_IMAGE_TAG` instead, or drop the guard entirely since CSB's
image is pulled at runtime by `openshell sandbox create`, not baked into
a Quadlet's `Image=` line the way the old derived image was — there's
nothing left for `podman build` to warn about missing.

- [ ] **Step 4: Build the image locally**

```bash
make build
make lint
```

Expected: `make build` succeeds with no reference to the removed
`IMAGE_OPENCLAW_OPENSHELL_URI`; `make lint` (bootc container lint) passes
with no new findings.

- [ ] **Step 5: Commit**

```bash
git add bootc/Containerfile Makefile
git commit -s -m "chore: retire tank-os's derived OpenClaw+OpenShell image and old bootstrap scripts"
```

---

### Task 5: Documentation sync

**Files:**
- Modify: `docs/provisioning.md`, `docs/cli.md`, `docs/openshell.md`,
  `docs/model-providers.md`, `docs/architecture-overview.md`,
  `docs/quickstart-prebuilt.md`, `docs/dev/sandbox-image-content.md`
- Modify: `docs/dev/csb-bootc-deployment-design.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Rename the sandbox everywhere it's referenced**

In `docs/openshell.md`, `docs/quickstart-prebuilt.md`,
`docs/architecture-overview.md`, and `docs/dev/sandbox-image-content.md`,
replace every `tankos-openclaw` reference with `tank-csb`, and update the
surrounding prose in each spot from "the tool-call sandbox OpenClaw's
plugin connects to" framing to "the sandbox OpenClaw itself runs inside"
(Finding C's one-sandbox model) — these are structural rewrites, not
find-and-replace, since the sandbox's *role* changed, not just its name.
`docs/architecture-overview.md:65`'s table row describing
`openshell-default--tankos-openclaw-*` as "where OpenClaw's tool-call
commands actually execute, isolated" needs its description rewritten
accordingly, not just the name swapped.

- [ ] **Step 2: Add setup examples for the three new secrets**

In `docs/provisioning.md`, after the existing "API Key Setup" section,
add:

```markdown
Execute the following commands to create secrets for xAI, Mistral, and
Cohere keys (all optional — CSB only reads whichever of these exist):

\```bash
sudo -iu openclaw
printf '%s' "$XAI_API_KEY" | podman secret create xai_api_key -
printf '%s' "$MISTRAL_API_KEY" | podman secret create mistral_api_key -
printf '%s' "$COHERE_API_KEY" | podman secret create cohere_api_key -
\```
```

(Un-escape the fenced code block's backticks when actually editing the
file — shown escaped here only so this plan's own Markdown renders
correctly.)

- [ ] **Step 3: Document the GitHub provider and the capability removal**

In `docs/model-providers.md`, add a short section noting that
`openai_api_key` and `gh_token` (the latter shared with service-gator)
now also back OpenShell providers consumed directly by the CSB sandbox,
and that `telegram_bot_token`, `openrouter_api_key`, and
`model_endpoint_api_key` are no longer supported after the CSB pivot
(link to `docs/dev/csb-bootc-deployment-design.md` Open Question 3 for
why). Do not delete the old sections outright if other parts of the doc
still reference them structurally — mark them clearly superseded instead,
so a reader mid-migration isn't left thinking a feature vanished silently.

- [ ] **Step 4: Update the design doc's own status**

In `docs/dev/csb-bootc-deployment-design.md`'s Status line, add a note
that the code implementation (this plan) is complete as of today's date,
referencing the PR(s) this work merges as. Cross-reference Finding L
(Task 2's supervision finding) from the Component Roles table's
"rewritten Quadlet/systemd unit" row.

- [ ] **Step 5: Lint and commit**

```bash
npx --no-install markdownlint-cli2 docs/provisioning.md docs/cli.md docs/openshell.md \
  docs/model-providers.md docs/architecture-overview.md docs/quickstart-prebuilt.md \
  docs/dev/sandbox-image-content.md docs/dev/csb-bootc-deployment-design.md
```

Expected: no *new* violations relative to each file's current baseline
(the repo already tolerates some pre-existing line-length violations —
don't introduce new ones, but don't feel obligated to fix unrelated
pre-existing ones either).

```bash
git add docs/
git commit -s -m "docs: sync docs with the CSB one-sandbox architecture"
```

---

### Task 6: End-to-end verification on a real VM

**Files:** none (verification only; may produce a small Finding M in the
design doc if anything unexpected turns up).

**Interfaces:** none.

- [ ] **Step 1: Apply the full change set to a running dev VM**

Rather than a full `make build && make build-qcow2` rebuild-and-reboot
cycle (heavyweight — reserve that for a pre-ship sanity check, noted in
Step 4), apply the rootfs changes directly to the same kind of VM Phase 0
used, matching this project's established hands-on-verification style:

```bash
scp bootc/rootfs/usr/libexec/tank-os/bootstrap-csb-sandbox \
    bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets \
    openclaw@<vm-ip>:/tmp/
scp bootc/rootfs/usr/lib/systemd/user/openclaw.service openclaw@<vm-ip>:/tmp/
# plus openclaw-healthcheck.service/.timer and check-csb-sandbox-health if Variant B
ssh openclaw@<vm-ip> bash -s <<'EOF'
set -euo pipefail
sudo cp /tmp/bootstrap-csb-sandbox /usr/libexec/tank-os/bootstrap-csb-sandbox
sudo chmod 0755 /usr/libexec/tank-os/bootstrap-csb-sandbox
sudo sed -i "s|__CSB_IMAGE_TAG_DEFAULT__|quay.io/redhat-et/openclaw:csb-2026.07.21|" \
  /usr/libexec/tank-os/bootstrap-csb-sandbox
cp /tmp/sync-podman-secrets /usr/libexec/tank-os/sync-podman-secrets
chmod 0755 /usr/libexec/tank-os/sync-podman-secrets
rm -f ~/.config/containers/systemd/openclaw.container
mkdir -p ~/.config/systemd/user
cp /tmp/openclaw.service ~/.config/systemd/user/openclaw.service
systemctl --user daemon-reload
EOF
```

- [ ] **Step 2: Fresh-boot behavior with no pre-existing secrets**

```bash
ssh openclaw@<vm-ip> "podman secret rm openclaw_gateway_token 2>/dev/null; systemctl --user restart openclaw.service"
sleep 20
ssh openclaw@<vm-ip> "systemctl --user status openclaw.service --no-pager; openshell sandbox get tank-csb; podman secret ls"
```

Expected: `openclaw_gateway_token` now exists (auto-provisioned by Step 1
of Task 1's script), `tank-csb` is `Ready`, the unit is `active
(running)` (Variant A) or `active` with `RemainAfterExit=yes` (Variant B).

- [ ] **Step 3: Dashboard reachability and restart safety**

```bash
ssh -L 18789:127.0.0.1:18789 openclaw@<vm-ip> "openshell forward start 18789 tank-csb --background 2>&1; curl -s -o /dev/null -w 'HTTP_%{http_code}\n' http://127.0.0.1:18789/"
```

In a browser on the local machine, open `http://127.0.0.1:18789/` through
that same SSH tunnel and confirm the OpenClaw dashboard loads — this is
the actual user-facing acceptance check, not just a curl status code.

Then restart twice in a row and confirm it comes back clean both times
(this exercises the delete-then-recreate idempotency Open Question 7
called out):

```bash
ssh openclaw@<vm-ip> "systemctl --user restart openclaw.service && sleep 15 && openshell sandbox get tank-csb"
ssh openclaw@<vm-ip> "systemctl --user restart openclaw.service && sleep 15 && openshell sandbox get tank-csb"
```

Expected: `Ready` both times, no leftover sandbox-name conflicts.

- [ ] **Step 4: Note the pre-ship follow-up**

Record in the design doc (or a short PR description note) that this
verification ran against a manually-patched dev VM, not a full
`make build && make build-qcow2` image — recommend that as a final sanity
check before this ships to real users, since it exercises the actual
`Containerfile`/`sed` substitution path Task 4 changed, which this task
didn't independently re-verify.

- [ ] **Step 5: Clean up and finish**

```bash
ssh openclaw@<vm-ip> "openshell sandbox delete tank-csb --force"
```

Use `superpowers:finishing-a-development-branch` from here — this is the
last task in the plan.
