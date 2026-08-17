# Security

This service is a Discord bot that reads a Nextcloud calendar and writes back to it. It accepts input from Discord, which is the untrusted side, and it holds credentials that reach further than Discord does. This document describes what it can touch, how it decides who is allowed to do what, and what was hardened on 2026-07-27.

## Blast radius

The stack holds four things worth protecting, in rough order of how much damage each one does if it leaks.

`NEXTCLOUD_PASS` is an app password for the delegator's Nextcloud account. It is not scoped to one calendar. Anything that account can read or write over WebDAV, this credential can read or write.

`DISCORD_BOT_TOKEN` is full control of the bot identity: it can read and send DMs to every user who shares a server with the bot.

`VAULT_BOT_TOKEN` is a Vault token the app uses at runtime to read and write per-delegation user maps. It is the only credential in the stack that a Discord user can indirectly cause to be used, through the `/add_user` slash command, so it gets the narrowest policy of anything here.

The AppRole SecretID under `runtime/vault-auth/` is what the Vault Agent authenticates with. It reads the stack's KV secret and nothing else. It is never mounted into the app containers.

## Trust boundaries

Discord is untrusted. Anything arriving from an interaction is attacker-controlled: the user id, the component that was clicked, the modal contents, and the timing.

Nextcloud is semi-trusted. Task titles, descriptions, categories and UIDs come from whoever can write to the delegator's calendar. They flow into log lines, DM text and internal state keys, so they are treated as data rather than as commands, and never as file paths.

Vault is trusted. The KV secret and `DELEGATIONS_JSON` are operator-controlled, so delegation ids and calendar URLs are taken at face value.

## Who is allowed to do what

There are two privileged actions and each has its own check.

Changing a task's status or deadline requires being an assignee of that task. The buttons and the deadline modal both compare the interacting user id against the assignee list stored for that task, and refuse anything else with an ephemeral reply. This is checked at the point of action, not at the point the message was sent, so it still holds for messages that were forwarded, for stale views re-registered after a restart, and for interactions that arrive on a message the bot no longer expects.

Editing a delegation's user map through `/add_user` requires being the delegator for that delegation. The command resolves the caller's delegations from `DELEGATIONS_JSON` and refuses both an unknown caller and a caller naming a delegation that is not theirs.

Nothing else in the bot acts on user input.

## What changed on 2026-07-27

**Interactions were unauthenticated.** The task buttons and the deadline modal parsed the task key out of the component id and acted on it, without ever checking who sent the interaction. Any interaction that reached the bot was honoured. A user who could reach one of those components could accept, complete, cancel or reschedule another person's task, and the change was written through to Nextcloud. Both paths now check assignee membership first and log rejections.

**Errors leaked internals into Discord.** Failures from the CalDAV client were formatted into the reply sent back to the user. Those exceptions routinely carry the internal Nextcloud URL and sometimes the request path. The bot now logs the exception and replies with a fixed message.

**Two secrets were written to the container logs.** `get_client()` printed `NEXTCLOUD_PASS` on every poll, so the delegator's app password was in `docker logs` and in any log shipper reading it. The Signal helper printed the full outbound payload, including recipient phone numbers. Both prints are gone. Note that if the old code ever ran against a real credential, that password should be rotated rather than reused.

**The app talked to Vault over plaintext HTTP.** `VAULT_ADDR` was hardcoded to `http://vault:8200`. On z1 the Vault listener is TLS only, so those calls could not succeed, but the same code pointed at a plaintext listener would have sent a Vault token in the clear. The address now comes from `.env`, and the private CA is mounted into both app containers with `REQUESTS_CA_BUNDLE` set, so certificate verification is on.

**The user map lived on the wrong mount.** The path was hardcoded to `secret/data/taskbot/config/user_map_dc/<id>`. That mount does not exist on this Vault, and it sits outside the prefix the stack's policies cover. It is now `VAULT_USER_MAP_PATH` under `kv/`, inside the namespace the bot token's policy is written against.

**The build could have shipped secrets in the image.** The ignore file was named `dockerignore` with no leading dot, so Docker ignored nothing and the build context was the entire stack root, `.env` and `runtime/` included. The context is now `app/`, which holds only application source, and there is a real `.dockerignore` in it.

**One container had no capability drop.** `signal-api` ran without `cap_drop: ALL` while every other service in the stack had it, and on a floating `:latest` tag. It is pinned now, on the rootless variant, with capabilities dropped.

**Unbounded input reached Vault.** `/add_user` wrote the supplied name straight into the stored map. It is capped at 64 characters.

**Component ids could crash the handler.** Task keys come from Nextcloud and may contain a colon, which broke the fixed three-way split of the component id and raised inside the callback. Parsing takes the action off the end instead.

## Container posture

Every service runs unprivileged: non-root user, `no-new-privileges`, `cap_drop: ALL`, bounded logs, and CPU and memory limits. The bot, poller and Vault Agent additionally run with a read-only root filesystem and writable `tmpfs` for `/tmp` and `/run`.

The stack has no inbound network surface. There is no published port, no Traefik router and no Tailscale node in the default configuration. All traffic is outbound: Discord over the internet, Nextcloud and Vault over internal Docker networks.

Secrets are rendered per consumer. The Vault Agent is the only container that mounts the whole `runtime/secrets/` tree. The bot and poller each mount only their own directory, read-only, and receive only the files they use. The AppRole credentials are never mounted into either.

## Known gaps

The AppRole SecretID is persistent (`VAULT_APPROLE_SECRET_ID_TTL=0`) because there is no rotation controller yet. This is a tracked template-wide risk rather than something specific to this service.

`VAULT_BOT_TOKEN` is a long-lived token. Rotating it means writing a new value to the KV secret and restarting the two app containers.

Any assignee of a task can act on it, including on behalf of other assignees of the same task. That is the intended model, but it is worth knowing that assignment is the whole authorization story.

Delegator notifications over Signal need `USER_MAP_SIGNAL`, which nothing currently renders. That path is inert rather than broken, and Signal is secondary to Discord here.

Task text from Nextcloud is sent into Discord messages without escaping. Discord markdown in a task title will render as markdown. It cannot execute anything, but it can be used to make a DM look like something it is not.

## If something goes wrong

Rotate in this order, because each one is independently useful to an attacker: the Discord bot token first, since it reaches users; then the Nextcloud app password, since it reaches data; then `VAULT_BOT_TOKEN`; then the AppRole SecretID. All four live in the stack's KV secret, so use `vault kv patch` to replace individual fields rather than `vault kv put`, which would wipe the rest of the secret.
