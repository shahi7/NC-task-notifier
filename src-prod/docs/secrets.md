# Secrets

Vault is the source of truth for service secrets.

## Setup

Run from the service repo:

```bash
cd /home/common/stacks/<service-name>
./scripts/setup-service.sh
```

Running without a mode opens the local/operator TUI. Choose the Vault/AppRole setup action from the menu, or use `./scripts/setup-service.sh --vault-only` for an explicit noninteractive mode. The script reads `/home/common/config/controls.env`, then `.env`, connects to the main Vault using `VAULT_API_ADDR`, and writes local Vault Agent auth files:

```text
runtime/vault-auth/role_id
runtime/vault-auth/secret_id
```

These files are runtime credentials, not backup artifacts. Keep the directory owner-only and install both files as `0400`; rotate them by atomically replacing the files. Never commit, archive, print, or restore an old pair. The current template retains persistent SecretIDs until a tested rotation controller exists, so the `0/0` SecretID settings are an explicitly tracked legacy risk rather than a recommended steady state.

## Rendering

Vault Agent reads those AppRole files and renders templates from `vault/templates/` into consumer-specific folders under:

```text
runtime/secrets/
```

Default consumers:

```text
runtime/secrets/bot/
runtime/secrets/poller/
runtime/secrets/ts-sidecar/
runtime/secrets/vault-agent/
```

Keep those folders separate. Each container should mount only the files it needs:

- `bot` mounts `runtime/secrets/bot/` at `/run/stack-secrets`.
- `poller` mounts `runtime/secrets/poller/` at `/run/stack-secrets`.
- `ts-sidecar` mounts `runtime/secrets/ts-sidecar/`.
- `vault-agent` writes all rendered secret folders and uses `runtime/secrets/vault-agent/` for its readiness marker.

The app should consume rendered secret files, not talk to Vault directly.

## Vault Agent launcher

Vault Agent should not be launched directly against raw HCL that still contains literal environment placeholders. The standard launcher:

1. validates `runtime/vault-auth/role_id` and `runtime/vault-auth/secret_id`,
2. renders `/vault/config/agent.hcl` to `/tmp/vault-agent.hcl`,
3. execs `vault agent -config=/tmp/vault-agent.hcl`.

This avoids Vault Agent rejecting literal values such as `$VAULT_STATIC_SECRET_RENDER_INTERVAL`.

Vault Agent uses its internal auto-auth token for templates. The template does not write a general-purpose token sink file.

## Tailscale Authkey

The setup script can generate a Headscale preauth key and store it in Vault as:

```text
tailscale_authkey
```

Vault Agent renders it to:

```text
runtime/secrets/ts-sidecar/tailscale_authkey
```

The Tailscale sidecar uses that file only when it needs to authenticate. The standard path is an unattended bootstrap join followed by server-side tagging in Headscale.

The `tailscale_authkey` key must always exist (non-empty) in the stack's KV secret, even after the node has joined. The vault-agent healthcheck requires the rendered file, and every template shares `exit_on_retry_failure`, so deleting the key from KV puts vault-agent into a restart loop and blocks the whole `depends_on` chain. Rotate the value in place; never remove the key.
