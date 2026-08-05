# CSB Bootc Deployment — Phase 0 Validation Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer Open Questions 1, 2, 6, and 7 from `docs/dev/csb-bootc-deployment-design.md` by hand-running redhat-et/openclaw-csb's published image inside an OpenShell sandbox on a real tank-os VM — before committing to rewriting `bootstrap-openshell-sandbox`, the Quadlet units, or `sync-podman-secrets`.

**Execution note (added 2026-08-05, after all 6 tasks ran):** several exact commands shown below — flag names (`--endpoint`, `service expose --port/--bind`), the missing trailing `-- /app/entrypoint.sh` on `sandbox create`, an unvalidated secret-lookup exit status, and a port-18789 collision with the VM's pre-existing baseline service — turned out to need correction once actually run against a live VM. Each correction, with the full investigation that found it, is recorded in `docs/dev/csb-bootc-deployment-design.md` (Open Questions 1, 2, 6, 7; Findings I, J; Future Considerations 5, 6) — that is the accurate, current reference. This file is preserved as the historical plan that guided that investigation, not retroactively rewritten command-by-command to match what was actually run.

**Architecture:** This is the design doc's own "Suggested first implementation step," executed as a checklist of manual, individually-verifiable actions against a locally-built tank-os qcow2 VM (the existing `docs/openshell.md` "Testing this locally end to end" flow), not new application code. Every task ends in a command whose output either confirms or refutes a specific claim in the design doc. Findings get written back into the design doc's Open Questions section as the deliverable — this phase produces verified facts, not a code diff. A second plan (code implementation: bootstrap script, Quadlet rewrite, `sync-podman-secrets` narrowing) follows once this phase's findings are in, since its concrete parameters (image tag, provider flags, forward vs. `service expose`) are presently unknown and cannot be planned without placeholders.

**Tech Stack:** existing tank-os `Makefile` (`make build`, `make build-qcow2`), qemu, the `openshell`/`openshell-gateway` RPMs (already installed on the tank-os host image per `bootc/Containerfile:46-54`), SSH, `quay.io/redhat-et/openclaw:csb-*` (redhat-et/openclaw-csb's published image).

## Global Constraints

- Do not modify `bootc/openclaw-openshell/`, the Quadlet units, or `sync-podman-secrets` in this phase — read-only validation on a live VM, plus doc updates only. No `bootstrap-openshell-sandbox` rewrite yet.
- All commands on the VM run as the `openclaw` user over SSH, never root, per `docs/provisioning.md`.
- Never pass a raw secret value as a literal `--credential KEY=VALUE` CLI argument (leaks via `ps`/`/proc/<pid>/cmdline`) — use `--from-existing` against a short-lived exported env var, or bare `--credential KEY`, per the design doc's Future Consideration 1.
- The tank-os host's `openshell` CLI and `openshell-gateway` are already present at the OS level (installed via `dnf` in `bootc/Containerfile`, not baked only into the OpenClaw container image) — no derived-image build is needed for this phase.
- Findings are written into `docs/dev/csb-bootc-deployment-design.md`'s existing "Open questions" section (resolving/annotating items 1, 6, 7), matching how Finding I was added after this doc's initial merge — not a new standalone doc.

---

### Task 1: Confirm CSB image tag and OpenClaw version/plugin parity (Open Question 1)

**Files:**
- Modify: `docs/dev/csb-bootc-deployment-design.md` (Open Question 1 entry, currently lines ~313-319)

**Interfaces:**
- Consumes: nothing (first task, no VM needed)
- Produces: `CSB_IMAGE_TAG` — the exact resolved tag string (e.g. `quay.io/redhat-et/openclaw:csb-amd64-2026.7.30`), used by Task 3 and Task 4

- [ ] **Step 1: Find the current published tag naming scheme**

```bash
git clone --depth 1 https://github.com/redhat-et/openclaw-csb /tmp/openclaw-csb-check
grep -n "OPENCLAW_REF\|csb-" /tmp/openclaw-csb-check/csb/Containerfile
grep -n "tags:\|IMAGE\|push" /tmp/openclaw-csb-check/.github/workflows/build.yml
```

Expected: a Containerfile `ARG OPENCLAW_REF=v2026.x.y` line and a workflow step showing the exact tag format pushed to `quay.io/redhat-et/openclaw`. Record the resolved tag as `CSB_IMAGE_TAG`.

- [ ] **Step 2: Compare OpenClaw version against tank-os's current pin**

```bash
grep -n "OPENCLAW_REF" /Users/panni/work/tank-os/bootc/openclaw-openshell/Containerfile
```

Compare that version against the `OPENCLAW_REF` found in Step 1. Note any gap (newer/older/same).

- [ ] **Step 3: Pull the resolved image locally and enumerate its plugin set**

```bash
podman pull "$CSB_IMAGE_TAG"
podman run --rm --entrypoint sh "$CSB_IMAGE_TAG" -c \
  'node -e "console.log(Object.keys(require(\"/home/node/.openclaw/openclaw.json\").plugins || {}))" 2>/dev/null || ls /home/node/.openclaw 2>/dev/null || echo "adjust path per actual image layout"'
```

Adjust the path/command once you see the image's actual layout (check `csb/entrypoint.sh` and `csb/configure-openclaw.mjs` from the clone in Step 1 for where config/plugins live). Expected outcome: a list of plugins/tools bundled by default.

- [ ] **Step 4: Check whether the image already includes an SSH client and the `openshell` CLI**

```bash
podman run --rm --entrypoint sh "$CSB_IMAGE_TAG" -c 'command -v ssh; command -v openshell; echo exit=$?'
```

This determines whether `bootc/openclaw-openshell/`'s entire reason for existing (Finding H / Component roles table: "adds SSH client + openshell CLI") is now redundant — if CSB's image already has both, tank-os's derived-image build step can be dropped entirely in the later implementation plan, not just its content changed.

- [ ] **Step 5: Record findings in the design doc**

Edit `docs/dev/csb-bootc-deployment-design.md`, Open Question 1 (~line 313-319), appending a dated finding: resolved tag, version comparison result, plugin-set comparison result, and the SSH/openshell-CLI-bundling verdict from Step 4.

- [ ] **Step 6: Commit**

```bash
cd /Users/panni/work/tank-os
git add docs/dev/csb-bootc-deployment-design.md
git commit -s -m "docs: record CSB image tag/parity findings (Open Question 1)

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 2: Boot an unmodified tank-os VM and confirm the OpenShell baseline

**Files:**
- None modified — this task produces a running VM as its deliverable, verified by SSH.

**Interfaces:**
- Consumes: nothing new
- Produces: `VM_IP` — the VM's IP address, used by every subsequent task

- [ ] **Step 1: Build the host image and qcow2**

```bash
cd /Users/panni/work/tank-os
make build
make build-qcow2
```

Expected: both complete without error, producing a qcow2 artifact (path per `Makefile`'s `build-qcow2` target output).

- [ ] **Step 2: Resize and boot per `docs/openshell.md`'s documented flow**

Follow `docs/openshell.md`'s "Testing this locally end to end" section exactly (`qemu-img resize`, then boot). Record `VM_IP` once cloud-init completes.

- [ ] **Step 3: Verify baseline SSH access and OpenShell presence**

```bash
ssh openclaw@$VM_IP "openshell --version && systemctl --user status openshell-gateway.service --no-pager"
```

Expected: a version string and `active (running)`. This confirms the Global Constraints' claim that OpenShell is present at the OS level, independent of the OpenClaw container — do not proceed if this fails.

- [ ] **Step 4: Verify the existing (unmodified) OpenClaw flow still works, as a rollback baseline**

```bash
ssh openclaw@$VM_IP "systemctl --user status openclaw.service --no-pager"
```

Record whether it's active. This is the fallback to compare against if the CSB sandbox approach hits a blocker later — no code changes happen in this task, so this should be unaffected by anything in this plan.

- [ ] **Step 5: Commit (only if `docs/openshell.md` needed a correction to follow)**

If Step 1-4 required deviating from what `docs/openshell.md` currently says (e.g. a stale command), fix that doc and commit:

```bash
git add docs/openshell.md
git commit -s -m "docs: correct stale local end-to-end testing steps

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

If no deviation was needed, skip this step — no commit for a no-op.

---

### Task 3: Hand-create OpenShell providers and the CSB sandbox (Open Question 7, secret-exposure caveat)

**Files:**
- Modify: `docs/dev/csb-bootc-deployment-design.md` (Open Question 7 entry, currently lines ~341-347)

**Interfaces:**
- Consumes: `VM_IP` (Task 2), `CSB_IMAGE_TAG` (Task 1)
- Produces: verified provider-creation command form, verified sandbox-creation command form — both feed directly into the later bootstrap-script implementation plan

- [ ] **Step 1: Push a test secret to the VM using the already-documented SSH-pipe method**

```bash
printf '%s' "$OPENAI_API_KEY" | ssh openclaw@$VM_IP "podman secret create test_openai_key -"
```

(Reuses the pattern already validated and documented in `docs/provisioning.md#injecting-secrets-from-the-host`.)

- [ ] **Step 2: On the VM, pull the secret into a short-lived env var and create a provider — verify the safe form works**

```bash
ssh openclaw@$VM_IP bash -s <<'REMOTE'
set -euo pipefail
export OPENAI_API_KEY="$(podman secret inspect --showsecret --format '{{.SecretData}}' test_openai_key)"
openshell provider create --name test-openai --type openai --from-existing
unset OPENAI_API_KEY
openshell provider list
REMOTE
```

Expected: `test-openai` appears in `provider list`, and at no point does the raw key appear in `ps aux` output (spot-check with a second concurrent SSH session running `ps aux | grep -i openshell` during Step 2, if timing allows).

- [ ] **Step 3: Test provider idempotency — run Step 2 a second time unchanged**

```bash
ssh openclaw@$VM_IP "openshell provider list | grep test-openai | wc -l"
```

Expected: `1`, not `2` — confirms whether `openshell provider create` with the same `--name` is a safe get-or-create, or errors/duplicates on a second boot. **Record the actual behavior** — this is the concrete answer Open Question 7 needs.

- [ ] **Step 4: Test the update path — change the secret value and re-run**

```bash
ssh openclaw@$VM_IP "podman secret rm test_openai_key" 2>&1 || true
printf 'rotated-value' | ssh openclaw@$VM_IP "podman secret create test_openai_key -"
# re-run Step 2's provider create with the same --name
```

Record whether `openshell provider create --name test-openai` on an existing name updates the credential or errors — determines whether the later bootstrap script needs `openshell provider update` instead.

- [ ] **Step 5: Test the removal path — what happens when a secret disappears**

```bash
ssh openclaw@$VM_IP "podman secret rm test_openai_key"
```

Then attempt a sandbox create that references `--provider test-openai` (Step 6) and observe the failure mode (does it fail closed with a clear error, per Finding A's stated behavior, or something else). This directly answers the "removal/detachment of providers whose backing secret has disappeared" part of Open Question 7.

- [ ] **Step 6: Create the CSB sandbox referencing the provider(s)**

```bash
ssh openclaw@$VM_IP "openshell sandbox create --from $CSB_IMAGE_TAG --name csb-spike --provider test-openai"
```

If Step 5 already removed the provider, recreate it first, then run this. Expected: sandbox reaches a running state; `csb/entrypoint.sh` (per Finding G) execs `openclaw gateway --allow-unconfigured` in the foreground inside it.

- [ ] **Step 7: Check for a Podman-secret-mounting equivalent for the non-provider-routed keys**

CSB's own `read_secret()` (Finding G) reads `/run/secrets/<name>` for keys it doesn't route through a provider (gateway token, anthropic/google/xai/mistral/cohere keys). Check whether `openshell sandbox create` supports mounting host Podman secrets the same way:

```bash
ssh openclaw@$VM_IP "openshell sandbox create --help" | grep -i secret
```

Record whether a `--secret`-equivalent flag exists. If not, this is a **new finding for the follow-up implementation plan** — flag it, don't try to solve it in this spike.

- [ ] **Step 8: Record findings in the design doc**

Edit `docs/dev/csb-bootc-deployment-design.md`'s Open Question 7 (~line 341-347), replacing the "needs a decision" framing with the actual verified behavior from Steps 3-5, plus a new bullet under Open Questions (or Future Considerations, if it's non-blocking) for Step 7's finding.

- [ ] **Step 9: Clean up test artifacts and commit**

```bash
ssh openclaw@$VM_IP "openshell sandbox delete csb-spike 2>/dev/null; openshell provider delete test-openai 2>/dev/null; podman secret rm test_openai_key 2>/dev/null" || true
cd /Users/panni/work/tank-os
git add docs/dev/csb-bootc-deployment-design.md
git commit -s -m "docs: record provider lifecycle findings from hands-on spike (Open Question 7)

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 4: Verify dashboard reachability — `forward` vs. `service expose` (Open Question 6)

**Files:**
- Modify: `docs/dev/csb-bootc-deployment-design.md` (Open Question 6 entry, currently lines ~348-353 after Task 1/3 edits shift line numbers — locate by heading text, not line number)

**Interfaces:**
- Consumes: `VM_IP` (Task 2), a running `csb-spike` sandbox (recreate from Task 3 Step 6 if it was cleaned up)

- [ ] **Step 1: Recreate the sandbox if Task 3 cleaned it up**

Repeat Task 3 Steps 1-2 and 6 (provider + sandbox create) if `csb-spike` no longer exists.

- [ ] **Step 2: Try `openshell forward` bound to guest loopback**

```bash
ssh openclaw@$VM_IP "openshell forward start 18789 csb-spike --background"
```

From your own machine:

```bash
ssh -L 18789:127.0.0.1:18789 openclaw@$VM_IP
```

Then open `http://localhost:18789` in a browser. Expected: dashboard loads, matching the existing documented UX in `docs/cli.md`.

- [ ] **Step 3: Tear down and try `service expose` instead**

```bash
ssh openclaw@$VM_IP "openshell forward stop 18789 csb-spike"
ssh openclaw@$VM_IP "openshell service expose csb-spike --port 18789 --bind 127.0.0.1:18789"
```

Repeat the same SSH-tunnel-and-browser check from Step 2. Specifically check for the two things Open Question 6 flags as undocumented: does it work over a websocket connection (the dashboard likely uses one for live updates), and does it work without a secure context (HTTPS) warning in the browser.

- [ ] **Step 4: Record the comparison and pick one**

Edit `docs/dev/csb-bootc-deployment-design.md`'s Open Question 6, recording which mechanism worked, and resolve the question with a concrete recommendation for the follow-up implementation plan.

- [ ] **Step 5: Commit**

```bash
cd /Users/panni/work/tank-os
git add docs/dev/csb-bootc-deployment-design.md
git commit -s -m "docs: resolve forward-vs-service-expose comparison (Open Question 6)

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 5: Verify `generic` providers for Forgejo/Jira (Open Question 2 / service-gator retirement)

Finding I hands-on-verified OpenShell's built-in `github` provider type and flagged Forgejo/Jira (no built-in type, would need `generic`) as untested. This task closes that gap so Open Question 2 ("service-gator's fate") can be answered with evidence instead of a guess.

**Files:**
- Modify: `docs/dev/csb-bootc-deployment-design.md` (Open Question 2 entry, locate by heading text — line numbers shift after Tasks 1/3/4 edits)

**Interfaces:**
- Consumes: `VM_IP` (Task 2)
- Produces: a verified verdict on whether `generic` providers cover Forgejo/Jira the same way `github` covers GitHub — gates whether `service-gator` is dropped entirely or kept for a narrower case in the follow-up implementation plan

- [ ] **Step 1: Push a test Forgejo (or Jira) token the same way as Task 3**

```bash
printf '%s' "$FORGEJO_TEST_TOKEN" | ssh openclaw@$VM_IP "podman secret create test_forgejo_token -"
```

- [ ] **Step 2: Create a `generic` provider with the token and Forgejo's API endpoint policy**

```bash
ssh openclaw@$VM_IP bash -s <<'REMOTE'
set -euo pipefail
export FORGEJO_TOKEN="$(podman secret inspect --showsecret --format '{{.SecretData}}' test_forgejo_token)"
openshell provider create --name test-forgejo --type generic \
  --credential FORGEJO_TOKEN --from-existing \
  --endpoint "https://<your-forgejo-host>/api/v1/*"
unset FORGEJO_TOKEN
REMOTE
```

Adjust the `--endpoint` value to your actual Forgejo instance; check `openshell provider create --help` on the VM for the exact flag name for endpoint/access-policy scoping under `generic` (this differs from the built-in types' auto-templated policy — Finding I notes `generic` has "no built-in endpoint-policy template").

- [ ] **Step 3: Attach to a throwaway sandbox and verify placeholder substitution + a real API call**

```bash
ssh openclaw@$VM_IP "openshell sandbox create --from $CSB_IMAGE_TAG --name generic-provider-spike --provider test-forgejo"
ssh openclaw@$VM_IP "openshell sandbox exec generic-provider-spike -- sh -c 'echo \$FORGEJO_TOKEN'"
```

Expected: the second command shows a placeholder (`openshell:resolve:env:...`), never the real token — matching Finding I's GitHub result. Then make one real read-only API call from inside the sandbox against your Forgejo instance to confirm the proxy actually resolves and forwards it.

- [ ] **Step 4: Repeat for Jira if a test Jira instance/token is available; otherwise document as still-untested**

If no Jira test credential is available, explicitly record that in the doc rather than silently skipping it — per the "no silent caps" principle, a gap should be visible, not implied as covered.

- [ ] **Step 5: Record the verdict and update Open Question 2**

Edit `docs/dev/csb-bootc-deployment-design.md`'s Open Question 2, replacing "Remaining work: verify Forgejo/Jira..." with the actual verdict: which of Forgejo/Jira were confirmed working via `generic` providers, and an explicit recommendation on `service-gator`'s fate (retire entirely / retire for confirmed types only / keep for untested types).

- [ ] **Step 6: Clean up and commit**

```bash
ssh openclaw@$VM_IP "openshell sandbox delete generic-provider-spike 2>/dev/null; openshell provider delete test-forgejo 2>/dev/null; podman secret rm test_forgejo_token 2>/dev/null" || true
cd /Users/panni/work/tank-os
git add docs/dev/csb-bootc-deployment-design.md
git commit -s -m "docs: verify generic providers for Forgejo/Jira (Open Question 2)

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 6: Final teardown, summary, and go/no-go for the code-implementation plan

**Files:**
- Modify: `docs/dev/csb-bootc-deployment-design.md` (top-of-doc Status line, currently line 3)

**Interfaces:**
- Consumes: all findings from Tasks 1, 3, 4, 5
- Produces: a go/no-go decision that gates writing the next plan (bootstrap script rewrite, Quadlet rewrite, `sync-podman-secrets` narrowing)

- [ ] **Step 1: Tear down the spike VM**

Shut down/delete the qemu VM instance used for this spike. No production VM exists yet, so there's nothing else to clean up.

- [ ] **Step 2: Update the doc's Status line**

Change line 3 from `Status: approved direction, not yet implemented.` to reflect the spike's outcome, e.g. `Status: approved direction; Phase 0 validation spike complete (see Open Questions 1/6/7), ready for implementation planning.` — or, if a blocker was found, describe it plainly instead of proceeding.

- [ ] **Step 3: Commit**

```bash
cd /Users/panni/work/tank-os
git add docs/dev/csb-bootc-deployment-design.md
git commit -s -m "docs: mark CSB bootc Phase 0 validation spike complete

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

- [ ] **Step 4: Open a PR for this branch**

```bash
git push -u origin feature/csb-bootc-integration
gh pr create --title "docs: CSB bootc deployment — Phase 0 validation spike findings" --body "Resolves Open Questions 1, 6, 7 from docs/dev/csb-bootc-deployment-design.md via hands-on VM testing. No code changes — see individual commits for per-question findings.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

If a blocker was found in any task that invalidates the design's core assumption (e.g., CSB's image can't run inside an OpenShell sandbox at all, or the provider mechanism doesn't fail closed on missing secrets), stop here and raise it for discussion rather than opening a routine PR — that's a design-level problem, not an implementation detail.
