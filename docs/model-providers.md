# Model Providers And Secrets

tank-os keeps model provider keys out of the image and out of any
persisted config file. Users add keys as rootless Podman secrets owned by
the `openclaw` user; `bootstrap-csb-sandbox` (the `ExecStart` of
`openclaw.service`) reads whichever of them exist on every start and wires
them into the `tank-csb` sandbox, either as an OpenShell `provider` or via
`--upload` plus a shell wrapper, depending on the key — see
`docs/dev/csb-bootc-deployment-design.md`'s Component Roles table and
Findings I/K for why credentials split across those two paths.

There is no separate "sync" step for these keys anymore: creating or
changing a secret and restarting `openclaw.service` is enough.

```bash
systemctl --user restart openclaw.service
```

## Supported Secrets

| Podman secret | How it reaches `tank-csb` | Notes |
| --- | --- | --- |
| `openclaw_gateway_token` | `--upload` + shell wrapper | Auto-provisioned on first start if not already set — see `docs/provisioning.md`'s Gateway Token Setup. |
| `openai_api_key` | OpenShell `provider` (`openai-claw`) | The sandboxed process only ever sees an OpenShell placeholder, never the real key. |
| `gh_token` | OpenShell `provider` (`github-claw`) | Same Podman secret service-gator already uses read-only for its own GitHub access — do not rename or duplicate it. |
| `anthropic_api_key` | `--upload` + shell wrapper | CSB routes this through its own `read_secret()`, not a provider (Finding G's mixed state — CSB isn't purer than this itself). |
| `gemini_api_key` | `--upload` + shell wrapper | Preferred Google key name; used if present. |
| `google_api_key` | `--upload` + shell wrapper | Alternate Google env name; used only if `gemini_api_key` is absent. |
| `xai_api_key` | `--upload` + shell wrapper | New since the CSB pivot — tank-os didn't support xAI before. |
| `mistral_api_key` | `--upload` + shell wrapper | New since the CSB pivot. |
| `cohere_api_key` | `--upload` + shell wrapper | New since the CSB pivot. |

All of the above except the gateway token are optional — CSB only reads
whichever keys have a corresponding secret. See `docs/provisioning.md`'s
API Key Setup section for the exact `podman secret create` commands.

## Superseded: `telegram_bot_token`, `openrouter_api_key`, `model_endpoint_api_key`

These three secret names are **no longer supported** after the CSB pivot.
tank-os's previous OpenClaw integration wrote them directly into
`openclaw.json` as custom channel/provider config; CSB generates its own
`openclaw.json` fresh on every start (`configure-openclaw.mjs`) and has no
equivalent hook for arbitrary channels or custom model endpoints today.
See `docs/dev/csb-bootc-deployment-design.md` Open Question 3 for the
open question this leaves (which existing tank-os docs/features still
apply unchanged under CSB) and for whether/how this gets revisited.

If you were relying on any of these, creating the Podman secret no longer
has any effect — there is nothing left to read it. This section is kept
rather than deleted so a reader mid-migration isn't left wondering whether
the feature silently vanished: it did, and this is why.

## Superseded: Custom Providers via Quadlet drop-in

The section below describes tank-os's previous mechanism for adding a
provider `openclaw.json` doesn't support out of the box (e.g. Moonshot),
by hand-writing a Quadlet secret drop-in plus custom `models.providers`
JSON. **This no longer works**: there is no more `openclaw.container`
Quadlet to attach a drop-in to, and CSB rewrites `openclaw.json` from
scratch on every start, so a hand-edited file would be discarded on the
next restart regardless. Kept for historical reference only, not as
working guidance.

### Old mechanism (pre-CSB, no longer functional)

A Podman secret by itself is not enough to create an arbitrary provider. OpenClaw
also needs the provider id, API adapter, base URL, and at least one model id.

Use a normal Podman secret for the key:

```bash
sudo -iu openclaw
printf '%s' "$MOONSHOT_API_KEY" | podman secret create moonshot_api_key -
mkdir -p ~/.config/containers/systemd/openclaw.container.d
cat > ~/.config/containers/systemd/openclaw.container.d/20-moonshot.conf <<'EOF'
[Container]
Secret=moonshot_api_key,type=env,target=MOONSHOT_API_KEY
EOF
systemctl --user daemon-reload
```

Then add the non-secret provider metadata to `~/.openclaw/openclaw.json`:

```json
{
  "secrets": {
    "providers": {
      "default": { "source": "env" }
    }
  },
  "models": {
    "providers": {
      "moonshot": {
        "baseUrl": "https://api.moonshot.ai/v1",
        "api": "openai-completions",
        "apiKey": { "source": "env", "provider": "default", "id": "MOONSHOT_API_KEY" },
        "models": [{ "id": "kimi-k2.5", "name": "Kimi K2.5" }]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "moonshot/kimi-k2.5" }
    }
  }
}
```
