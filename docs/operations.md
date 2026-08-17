# Operations

## Setup

Always run Compose commands from the stack root. Relative bind mounts such as `./runtime/vault-auth`, `./runtime/secrets`, and `./data/tailscale` resolve from the current working directory, not from `/home/common` globally.

```bash
cd /home/common/stacks/nc-taskbot
cp .env.example .env
nano .env
./scripts/setup-service.sh        # opens the local/operator TUI by default
./scripts/setup-service.sh --bootstrap-only
sudo docker compose --env-file .env up -d --force-recreate --remove-orphans
```

`--bootstrap-only` is safe to rerun. Use it before first start, after restoring files, or after a container-created runtime file leaves ownership/mode bits inconsistent.

## Setup TUI

`setup-service.sh` opens the local/operator TUI when run without a mode:

```bash
cd /home/common/stacks/nc-taskbot
./scripts/setup-service.sh
```

Use only the implemented explicit flags for operator automation. Application deployment CI does not run Vault provisioning. Examples:

```bash
./scripts/setup-service.sh --bootstrap-only -y
./scripts/setup-service.sh --vault-only --skip-env-import -y
```

## Bootstrap only

```bash
cd /home/common/stacks/nc-taskbot
./scripts/setup-service.sh --bootstrap-only
```

Run with `sudo` when runtime ownership needs normalization:

```bash
cd /home/common/stacks/nc-taskbot
sudo ./scripts/setup-service.sh --bootstrap-only
```

This normalizes root-owned Tailscale state and the shared secrets/auth directories instead of adding extra filesystem capabilities to the sidecar.

## Vault only

```bash
cd /home/common/stacks/nc-taskbot
./scripts/setup-service.sh --vault-only
```

## Optional service bootstrap

If the service needs application state before it can become healthy, implement:

```text
hooks/bootstrap-service-state.sh
```

The disabled CI release contract can run that hook directly when `BOOTSTRAP_SERVICE_STATE=true`. Keep it false until the hook has idempotency and rollback tests. A manual operator can run:

```bash
bash hooks/bootstrap-service-state.sh
```

## Restart

```bash
cd /home/common/stacks/nc-taskbot
sudo docker compose --env-file .env restart
```

## Logs

```bash
cd /home/common/stacks/nc-taskbot
sudo docker compose --env-file .env logs --tail=100 vault-agent
sudo docker compose --env-file .env logs --tail=100 bot
sudo docker compose --env-file .env logs --tail=100 poller
```

The poller is the noisy one. If assignees are not receiving DMs, start there: it prints the resolved user map for each delegation, so an empty map points at Vault or at the delegation id rather than at Discord.

## Re-render Vault Secrets

```bash
cd /home/common/stacks/nc-taskbot
sudo docker compose --env-file .env restart vault-agent
```

Vault Agent is launched through `scripts/start-vault-agent.sh`. The launcher validates `role_id` and `secret_id`, renders `/vault/config/agent.hcl` to a temporary HCL file with concrete environment values, then execs `vault agent`. Do not point the container directly at raw HCL that still contains literal `$VARIABLE` placeholders.

Launcher scripts that are bind-mounted into containers should be invoked as `entrypoint: ["/bin/sh", "/usr/local/bin/<script>.sh"]`, not executed directly as `/usr/local/bin/<script>.sh`. On June 7, 2026 this caused `Permission denied` failures in `p1-hs-vault-agent` even though the host script itself had the execute bit set.

## Tailscale Reauth

Only applies if the optional `tailnet` profile is running; it is off by default. Add `--profile tailnet` to the commands below.

Use a one-shot control file. Do not leave reauth enabled in `.env`.

```bash
cd /home/common/stacks/nc-taskbot
touch runtime/control/tailscale-force-reauth
sudo docker compose --env-file .env up -d --force-recreate ts-sidecar
```

Standard path:

1. Store a reusable bootstrap authkey in Vault as `tailscale_authkey`.
2. Keep `TS_LOGIN_SERVER` as the only source for `--login-server`.
3. Keep `TS_EXTRA_ARGS` for steady-state flags such as `--accept-dns=false`.
4. Keep `TS_BOOTSTRAP_EXTRA_ARGS` empty unless a one-off extra flag is genuinely needed. The shared launcher clears `--advertise-tags` during bootstrap or reauth by default, so an untagged authkey does not inherit stale tag settings from a previous run.
5. Wait for `tailscale --socket=/run/tailscale/tailscaled.sock status --json` to show `BackendState: Running`.
6. Apply final tags server-side in Headscale.

These Linux sidecars do not use Tailscale's `--unattended` flag. The current Tailscale CLI documents that flag as Windows-only, so the unattended path here is the reusable auth key passed to `tailscale up`.

The reviewed standalone operator helper is:

```bash
cd /home/common/stacks/nc-taskbot
./scripts/retag-headscale-node.sh
```

If the sidecar prints an auth URL or stays in `NeedsLogin`, treat that as a failure. New service sidecars are expected to start through the reusable auth key with no browser login.

## Archiving replaced stacks

Archive immutable source and application data separately. Never archive `.env`, `runtime/vault-auth`, rendered secrets, registry credentials, Tailscale bootstrap keys, or TLS private material with the source tree. Revoke old AppRole SecretIDs/tokens before decommissioning a stack.

Example:

```bash
sudo install -d -m 700 /home/common/archive
git archive --format=tar HEAD > /home/common/archive/<service>-source.tar
```

Encrypt and authenticate application-data backups separately and keep the encryption key outside the backup location.
