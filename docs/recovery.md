# Recovery

## Recreate runtime folders

Always run from the stack root:

```bash
cd /home/common/stacks/<service-name>
./scripts/setup-service.sh --bootstrap-only
```

If ownership drift is suspected, rerun bootstrap with sudo:

```bash
cd /home/common/stacks/<service-name>
sudo ./scripts/setup-service.sh --bootstrap-only
```

## Recreate Vault auth

Never restore an old `role_id` or `secret_id` from backup. Recreate the declared policy/AppRole through the administrator workflow, mint fresh credentials, and install them atomically with owner-only permissions. Verify the retired SecretID/accessor no longer authenticates.

Prepare the empty runtime directory first:

```bash
sudo ./scripts/setup-service.sh --bootstrap-only
```

## Restore app data

Restore service data into:

```text
data/app/     task state, queues, and CalDAV sync tokens
data/signal/  signal-cli registration state
```

`data/app/` is the one that matters. Losing it means the bot forgets which tasks it has already sent, which reminders went out, and where each calendar sync left off, so the next poll re-sends. The user maps live in Vault, not here.

## Tailscale recovery

Only applies if the optional `tailnet` profile is running; it is off by default and this stack does not need it.

Use the standard sidecar recovery path:

1. Write a reusable bootstrap authkey into Vault as `tailscale_authkey`.
2. Confirm Vault Agent renders it to `runtime/secrets/ts-sidecar/tailscale_authkey`.
3. Create `runtime/control/tailscale-force-reauth`.
4. Recreate only the sidecar, or recreate the stack from the stack root.
5. Confirm the sidecar reached `BackendState: Running` without an auth URL or a stuck `NeedsLogin` state.
6. Apply final tags through the administrator-owned Headscale workflow. On the Headscale host, the reviewed operator helper is `./scripts/retag-headscale-node.sh`.

Do not use persistent reauth flags in `.env`, do not place control files in `data/tailscale/`, and do not restore bootstrap tags through `TS_BOOTSTRAP_EXTRA_ARGS` unless you are intentionally testing a one-off tagged join.

Then redeploy:

```bash
cd /home/common/stacks/<service-name>
sudo docker compose --env-file .env up -d --force-recreate
```

## Tailscale state ownership

`data/tailscale/` is root-owned service state. If tailscaled reports chmod/chown failures, fix the host-side directory with bootstrap instead of adding `CHOWN` or `FOWNER` to the container:

```bash
cd /home/common/stacks/<service-name>
sudo ./scripts/setup-service.sh --bootstrap-only
sudo docker compose --env-file .env up -d --force-recreate ts-sidecar
```

## Service bootstrap recovery

If the service implements `hooks/bootstrap-service-state.sh`, treat failures in that hook as a separate recovery class. Fix the Vault/bootstrap inputs first, run the hook directly under the operator runbook, then recreate the stack.

## Archived predecessor stacks

Restore source from a verified Git commit or sanitized source archive. Restore application state only from an authenticated encrypted backup. Do not restore AppRole files, `.env`, rendered secrets, bootstrap credentials, or TLS keys from a predecessor stack; mint or restore each through its authoritative control plane.

Example archive path:

```text
/home/common/archive/<service-name>-YYYYMMDD
```
