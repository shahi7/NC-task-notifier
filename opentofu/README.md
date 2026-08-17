# Service Template OpenTofu

Metadata-only OpenTofu root for the deployed nc-taskbot service at `/home/common/zeppelin1/nc-taskbot`.

It documents the expected stack path, compose project name, optional application FQDN and port, Vault path(s), required external networks, optional service-bootstrap intent, dependent Vault paths, and the standard Tailscale bootstrap/recovery model without managing any real resources.

Recorded Tailscale intent:

- reusable bootstrap authkey stored in Vault as `tailscale_authkey`
- unattended bootstrap join against `https://h.onsaa.org`
- one-shot reauth trigger at `runtime/control/tailscale-force-reauth`
- final service tags applied server-side after the node reaches `Running`

Recorded bootstrap intent:

- whether first-run service bootstrap is required
- which local artifacts that bootstrap is expected to create
- which dependent Vault KV paths may be updated by that bootstrap

Use:

```bash
cd /home/common/zeppelin1/nc-taskbot/opentofu
tofu init -backend=false
tofu validate
tofu plan
```

## Operator-provided inputs

These values are not created by the template. An operator must provide them either through GitLab CI/CD protected variables or during manual bootstrap.

### Control-plane and deploy access

- `DEPLOY_TARGET`
  - `p1` or `z1`
  - or explicit `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY_VAR`
- `DEPLOY_STACK_PATH`
  - explicit protected path below `/home/common/stacks`
- `SSH_PRIVATE_KEY_P1`
  - deploy key for p1-hosted stacks
- `SSH_PRIVATE_KEY_Z1`
  - deploy key for z1-hosted stacks
- `SSH_KNOWN_HOSTS`
  - pinned host keys for deploy targets

### Vault bootstrap inputs (operator workflow only)

- `VAULT_TOKEN_FILE`
  - local file used only by the administrator provisioning workflow
  - never expose it to application deployment CI or pass it in argv/environment
- `VAULT_API_ADDR`
  - main Vault API address reachable from the deploy host or operator shell
- `VAULT_API_CACERT`
  - CA bundle path for the main Vault API
- `VAULT_SKIP_VERIFY`
  - only when intentionally bypassing TLS verification

The CI deploy job requires pre-provisioned `.env` and AppRole files and rejects Vault parent/bootstrap credentials.

### Service identity inputs

- `HOST_ID`
  - usually `p1` or `z1`
- `SERVICE_ID`
  - short service identifier used in compose project/container naming
- `STACK_NAME`
  - repository/runtime directory name for the service
- `VAULT_KV_PATH`
  - KV v2 API path used by Vault Agent, for example `kv/data/<service>`
- `VAULT_APPROLE_NAME`
  - AppRole name for the service
- `VAULT_POLICY_NAME`
  - Vault policy name for the service

### Tailscale / Headscale inputs

- `TS_HOSTNAME`
  - node hostname used during bootstrap join
- `tailscale_authkey`
  - stored in the service KV path as a reusable bootstrap authkey
- `TS_LOGIN_SERVER`
  - usually `https://h.onsaa.org`
- `TS_FINAL_TAGS`
  - final tags applied after the node reaches `Running`
- `HEADSCALE_CONTAINER`
  - local Headscale container name when tagging runs on p1
- `HEADSCALE_HOST`
  - remote Headscale control host when deploy and control plane differ
- `HEADSCALE_REMOTE_USER`
  - SSH user for that control host

### Standard manual bootstrap artifacts

These are created by the operator workflow and must exist before a first deploy can succeed:

- `runtime/vault-auth/role_id`
- `runtime/vault-auth/secret_id`
- any service-specific bootstrap artifacts created by `hooks/bootstrap-service-state.sh`

### App-specific secrets

This template does not enumerate application secrets. Operators must also seed the service KV path with whatever app-level secrets the service needs in addition to the platform/bootstrap inputs above.
