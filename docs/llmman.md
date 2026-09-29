# llmman

[llmman](https://github.com/llmmanorg/llmman) serves local models behind
one Ollama/OpenAI/Anthropic-compatible endpoint, and stores and distributes
the models themselves as plain OCI artifacts. That is the same story bootc
tells for the OS image: pull from any registry you already trust (Docker
Hub, GHCR, quay, Harbor, a self-hosted mirror), sign with cosign, mirror
for air-gapped sites, and keep no separate model-hub account or blob format.

tank-os installs the `llmman` binary into the image at `/usr/bin/llmman`
and runs `llmman serve` as a rootless systemd *user* service owned by
`openclaw`, enabled at build time so it comes up on every boot:

```text
/usr/lib/systemd/user/llmman.service
```

Because `openclaw` has lingering enabled, the unit starts at boot without
anyone logging in, alongside `openshell-gateway.service` and
`openclaw.service`.

## Versioning

Unlike the OpenShell RPMs, llmman is **not pinned** in
`bootc/Containerfile`. Every llmman commit that passes CI is a release and
there is no separate stable channel, so each tank-os build fetches the
current GitHub release for the target architecture and verifies it against
that release's own `checksums.txt`. Two tank-os images built at different
times can therefore carry different llmman versions; `llmman --version`
on the booted VM reports which one you have.

## Endpoint

The daemon listens on loopback only:

```text
http://127.0.0.1:17434
```

| API | Endpoints |
|-----|-----------|
| Ollama | `/api/chat`, `/api/generate`, `/api/embed`, `/api/tags`, `/api/ps`, `/api/pull`, ... |
| OpenAI | `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`, `/v1/responses` |
| Anthropic | `/v1/messages` |

A web UI is served at `/`. Reach it from your workstation the same way as
the OpenClaw dashboard, over an SSH tunnel:

```bash
ssh -N -p <port> -L 17434:127.0.0.1:17434 openclaw@localhost
```

## Pull and run a model

As the `openclaw` user:

```bash
sudo -iu openclaw
llmman pull qwen3.8                          # short name resolved via Docker Hub
llmman pull hf.co/unsloth/Qwen3.5-0.8B-GGUF  # or straight from Hugging Face
llmman run qwen3.8                           # chat
llmman list
llmman ps
```

Models are stored as an OCI Image Layout under
`~openclaw/.local/share/llmman/store`, which is on the mutable `/var`
filesystem, so pulled models survive `bootc upgrade` / `bootc switch` and
are not part of the OS image itself.

Move a model into your own registry without it ever landing on the VM:

```bash
llmman transfer hf.co/unsloth/Qwen3.5-0.8B-GGUF quay.io/myorg/qwen3.5:latest
```

## Inference engine

On first use llmman fetches a tested upstream `llama.cpp` release matching
the detected hardware; on Linux with a container engine available that is
a container image, otherwise a prebuilt binary. GPU detection happens at
runtime inside `llmman serve`, not at image build time. See
[docs/backends.md](https://github.com/llmmanorg/llmman/blob/main/docs/backends.md)
upstream for the `--runtime` and `LLMMAN_RUNTIME` options.

For an air-gapped host, set `LLMMAN_RUNTIME=path` with your own
`llama-server` on `PATH` (nothing is downloaded) and pre-stage models from
your mirror with `llmman pull` or `llmman transfer`.

## Configuration

System-wide settings go in `/etc/llmman/llmman.conf`; per-user settings in
`~openclaw/.config/llmman/llmman.conf`. `llmman config set ...` edits the
latter. Daemon-wide environment variables (`LLMMAN_HOST`,
`LLMMAN_MODELS`, `LLMMAN_CONTEXT_LENGTH`, ...) belong in a drop-in:

```bash
sudo -iu openclaw
mkdir -p ~/.config/systemd/user/llmman.service.d
cat > ~/.config/systemd/user/llmman.service.d/10-env.conf <<'EOF'
[Service]
Environment=LLMMAN_KEEP_ALIVE=30m
EOF
systemctl --user daemon-reload
systemctl --user restart llmman.service
```

Binding beyond loopback (`LLMMAN_HOST=0.0.0.0`) requires API keys, or
`llmman serve` refuses to start. Set them with
`llmman config set auth.api_keys <key>`, which keeps the file owner-only.
If you use `LLMMAN_API_KEYS` in a drop-in instead, `chmod 600` that file.
`LLMMAN_AUTH=off` skips the requirement and disables daemon-side
authentication, so use it only behind an authenticating gateway.

Keys travel with every request, so also terminate TLS in the daemon
(`LLMMAN_TLS_CERT`, `LLMMAN_TLS_KEY` and an `https://` `LLMMAN_HOST`) or
keep access behind an SSH tunnel or gateway. Upstream's
[configuration.md](https://github.com/llmmanorg/llmman/blob/main/docs/configuration.md)
documents every variable.

## Service management

```bash
systemctl --user status llmman.service
systemctl --user restart llmman.service
journalctl --user -u llmman.service -f
```

## Not yet wired into OpenClaw

`llmman.service` and the `tank-csb` sandbox are independent today. OpenClaw
inside the sandbox is not automatically configured to use the host's
llmman endpoint as a model provider; CSB regenerates `openclaw.json` on
every start and the sandbox's network policy governs what it can reach
(see `docs/model-providers.md` and `docs/openshell.md`). Pointing OpenClaw
at `http://127.0.0.1:17434/v1` from inside the sandbox is a follow-up.
