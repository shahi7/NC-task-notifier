# Permissions

The template keeps expected modes in [permissions.tsv](/home/common/service-template-v2/permissions.tsv).

Use from the stack root:

```bash
cd /home/common/stacks/<service-name>
./scripts/permissions.sh check
./scripts/permissions.sh apply
```

Use sudo when runtime ownership has drifted or a container created root-owned files:

```bash
cd /home/common/stacks/<service-name>
sudo ./scripts/setup-service.sh --bootstrap-only
```

Rules of thumb:

- Production source belongs to a dedicated infrastructure-administrator group, never `nogroup` or a runtime consumer group.
- Source directories are `2750`; regular committed files are `0640`; executable helpers are `0750`. Only the owner may modify deployed source.
- `.env` is `0600` and must not be copied into source archives or staging.
- `runtime/vault-auth/` is `0700`; `role_id` and `secret_id` are `0400` and are never group-writable.
- Vault Agent rendered secret files are `0440` and live under consumer-specific subdirectories (`runtime/secrets/app/`, `runtime/secrets/ts-sidecar/`, `runtime/secrets/vault-agent/`).
- Optional runtime files such as `.env`, AppRole material, and runtime secret renders are only validated when they exist; rendered files can also be marked `nonempty`.
- `data/tailscale/` is root-owned Tailscale state. Normalize it during bootstrap instead of granting `CHOWN` or `FOWNER` to the sidecar.
- Prefer a separate read-only consumer group for each rendered-secret directory. A single `STACK_SECRETS_GID` is a compatibility fallback, never the owner of `runtime/vault-auth` or production source.

The current permission tools validate mode and file type. Owner/group enforcement and a controlled migration from existing `nogroup` ownership remain required before production deployment from this template is enabled.
