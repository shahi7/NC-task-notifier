# Architecture

The stack has four default services and must be operated from its own stack root at `/home/common/stacks/nc-taskbot/`.

Relative bind mounts in Compose are part of the contract. Running Compose from another directory can point `./runtime/secrets`, `./runtime/vault-auth`, or `./data/app` at the wrong tree and create false startup failures.

Nothing here listens on HTTP. Both application processes are outbound only: Discord over the internet, Nextcloud and Vault over internal Docker networks. There is no published port and no Traefik router in the default configuration.

## bot

The long-running Discord client. It processes the DM queue, renders task buttons, writes assignee decisions back to Nextcloud, and serves the `/add_user` slash command.

It mounts only `runtime/secrets/bot/`, plus the Vault CA so its own Vault calls can verify TLS. Its state lives in `data/app/`, shared with the poller.

## poller

A supercronic process that runs `dc_script.py` every five minutes. It reads each delegation's calendar over CalDAV, resolves assignees from the user maps in Vault, and writes DM jobs into the queue the bot drains.

It mounts only `runtime/secrets/poller/`, which is a strict subset of the bot's secrets: no Discord token.

## signal-api

Local signal-cli REST API for delegator notifications. Secondary to the Discord path, reachable only on `stack-internal`, with its state in `data/signal/`.

## app image

Both application services run one image built from `app/`, which holds only application source. Set `APP_IMAGE` to a promoted registry digest to run a published build instead of a local one.

## vault-agent

Authenticates to the main Vault with AppRole and renders secrets into consumer-specific folders under `runtime/secrets/`.

The container uses the shared stack secrets group so it can read `runtime/vault-auth/` and write rendered secret files for the other containers.

Vault Agent is started by `scripts/start-vault-agent.sh`, which validates auth files and renders a temporary concrete HCL config before execing `vault agent`.

## ts-sidecar (optional)

Off by default since 2026-07-27. It sits behind the `tailnet` Compose profile, because no service here needs an inbound route. Start it with `docker compose --profile tailnet up -d`, and expect to add a Headscale ACL grant before the node can reach or be reached by anything.

When enabled it owns Tailscale/Headscale identity, joins `edge_proxy`, and carries Traefik labels. The active router uses `tailsecure`; `websecure` is commented out by default. Note that the router has no upstream unless an application service is also given `network_mode: "service:ts-sidecar"`.

`data/tailscale/` is persistent root-owned Tailscale state. Bootstrap normalizes that path on the host instead of expanding the sidecar capabilities beyond `NET_ADMIN` and `NET_RAW`.

Tailscale argument ownership:

```text
TS_LOGIN_SERVER        owns --login-server
TS_EXTRA_ARGS          steady-state tailscale up flags
TS_BOOTSTRAP_EXTRA_ARGS rare one-off extras only
```

The standard lifecycle is:

1. join with a reusable untagged authkey from Vault
2. let the sidecar reach `Running`
3. apply `TS_FINAL_TAGS` server-side in Headscale

The shared launcher clears `--advertise-tags` by default during bootstrap or reauth unless `TS_BOOTSTRAP_EXTRA_ARGS` explicitly provides a temporary tag override.
