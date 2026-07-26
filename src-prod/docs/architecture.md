# Architecture

The stack has three default services and must be operated from its own stack root under `/home/common/stacks/<service-name>/`.

Relative bind mounts in Compose are part of the contract. Running Compose from another directory can point `./runtime/secrets`, `./runtime/vault-auth`, or `./data/tailscale` at the wrong tree and create false startup failures.

## app

The application container. It shares the sidecar network namespace with:

```yaml
network_mode: "service:ts-sidecar"
```

It mounts only app-specific rendered secrets from `runtime/secrets/app/`.

## vault-agent

Authenticates to the main Vault with AppRole and renders secrets into consumer-specific folders under `runtime/secrets/`.

The container uses the shared stack secrets group so it can read `runtime/vault-auth/` and write rendered secret files for the other containers.

Vault Agent is started by `scripts/start-vault-agent.sh`, which validates auth files and renders a temporary concrete HCL config before execing `vault agent`.

## ts-sidecar

Owns Tailscale/Headscale identity, joins `edge_proxy`, and carries Traefik labels. The active router uses `tailsecure`; `websecure` is commented out by default.

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
