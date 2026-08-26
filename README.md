## Latest Updates

- Store secrets in Vault
- Scale the software to support multiple delegators/calendars
- Allow delegator(s) to add assignee name/Discord username (Discord slash command /add_user)

### 2026-07-27: renamed to nc-taskbot, and the z1 deploy fixes

The service is called `nc-taskbot` now, top to bottom: repo folder, Vault paths, AppRole and policy names, and the `z1-tb-*` container names. It deploys to `/home/common/stacks/nc-taskbot`.

Every change below is marked in the file it touches with a `fix 2026-07-27` comment saying what was wrong.

What was actually broken:

- The image never contained a runnable app. The build copied the whole stack root, so the code landed in `/app/image/` while the start command looked for `/app/dc_bot.py`. The build context is `app/` now, and there is a real `.dockerignore` next to the Dockerfile. The old root `dockerignore` had no leading dot, so Docker ignored nothing and could not even read the root-owned `runtime/` directories.
- The poller could never find an assignee. It read `USER_MAP_DC__<id>`, which no env var and no Vault template ever supplied, so it quietly defaulted to an empty map and queued no DMs. It now reads the same Vault path the `/add_user` slash command writes to.
- That Vault path pointed at a `secret/` mount we do not have. Everything lives under `kv/`, so the path comes from `VAULT_USER_MAP_PATH` and both processes share it.
- The bot talked to Vault over `http://vault:8200`. Vault on z1 is TLS only, so those calls could never succeed. Both processes now use the same address and CA certificate as the Vault Agent.
- `NEXTCLOUD_INTERNAL_NETWORK` named a network that does not exist on z1. The real one is `z1_nc_stack-internal`, and since Compose treats it as external, the stack would not have started at all.
- The Vault CA paths were the p1 layout. On z1 the certificate is at `/home/common/stacks/vault-z1/tls/ca.crt`.
- `get_client()` printed the Nextcloud app password on every poll, straight into the container logs.
- Queue cleanup globbed `queue/` relative to the working directory, so it never saw the real queues under `/app/data/queue`.

What moved rather than broke:

- The Tailscale sidecar sits behind a `tailnet` Compose profile, so it does not start by default. Nothing here listens on HTTP, so its Traefik router had no upstream, and a new tailnet node would need a Headscale ACL grant before anything could reach it. Its `extra_hosts` pointed at `172.21.0.10`, an address that exists nowhere on z1; it now uses the public Headscale IP like every other z1 sidecar. Bring it back with `docker compose --profile tailnet up -d`.
- Because the sidecar is off by default, the Vault Agent healthcheck no longer waits for `tailscale_authkey`. It would otherwise stay unhealthy forever and block the bot and poller from starting.
- signal-cli moved to `data/signal/` and its image is pinned to the rootless variant, since the service runs as a non-root user and could not write its own state directory before. Signal is the secondary path here; Discord is the one that matters. Delegator Signal messages still need `USER_MAP_SIGNAL`, which nothing renders yet.

The security side of this work, plus the bot's trust boundaries and who is allowed to do what, is written up in [docs/security.md](docs/security.md).

Deployment still needs a few things that live outside this repo: the Vault KV secret and AppRole on z1, `.env` and `runtime/vault-auth/` on the target, and, if you want the CI deploy path rather than a hand deploy, `ci/approved-images.lock` with promoted registry digests.

### Service-template cleanup

The Compose stack now follows the current service-template conventions. The local development Vault service and its shared secrets volume were removed. Vault Agent now authenticates to the managed Vault with this stack's AppRole, then renders only the files each process needs.

- `bot` receives `runtime/secrets/bot/`, mounted as `/run/stack-secrets`.
- `poller` receives `runtime/secrets/poller/`, mounted at the same path.
- `ts-sidecar` keeps its separate `runtime/secrets/ts-sidecar/` directory.
- The agent is the only container allowed to mount the complete secrets root.

This keeps the familiar in-container secret path while preventing one process from reading another process's credentials. The bot and poller wait for their rendered files before starting, so they do not race Vault Agent on boot.

The application containers now use the shared app UID/GID, bounded logs, resource limits, a read-only root filesystem, and dropped Linux capabilities. Container names follow the standard `${HOST_ID}-${SERVICE_ID}-<role>` pattern.

For Nextcloud, the bot and poller use `http://nextcloud` over the shared Docker network rather than routing same-host CalDAV traffic through the Tailnet. Nextcloud must trust the `nextcloud` hostname for this direct route.

Non-secret settings stay in `.env`; passwords, tokens, and delegation data belong in Vault and are rendered through the templates in `vault/templates/`.

---

# Discord Task Bot Guide

This is an overview to the Discord task bot and a simple usage and onboarding guide.

## Purpose

The system connects Nextcloud tasks to Discord DMs so assignees can receive task notifications, update task status and deadlines, and get follow-up reminders or updates when task details change in Nextcloud.

The polling script checks the Nextcloud calendar for new and changed tasks, writes notification jobs into a queue, and the Discord bot processes that queue and sends DMs.

## Core features

- New tasks are shared with tagged assignees by Discord DM.
- Interactive task buttons in Discord for status updating (such as accepting or completing a task).
- Ability for assignees to extend task deadlines.
- Follow-up reminder messages.
- Send update notifications when task details such as deadline, description, subject, or location change in Nextcloud.
- Send task DMs to newly added assignees and notify removed assignees of removal.
- Retry queue to work around temporary Discord/Nextcloud network failures.

## How work flows

1. A delegator creates or modifies a task in Nextcloud.
2. The polling script reads new/modified tasks from the tasks calendar.
3. The script stores task metadata locally.
4. A DM job is queued for each target Discord user.
5. The bot processes the DM queue and sends/follows-up in Discord DMs.
6. Assignees interact with the DM to update task state or deadline.
7. The system syncs assignee updates back to Nextcloud.

## Delegator setup

Delegators are the people creating and assigning tasks in Nextcloud.

- Use the correct shared Nextcloud calendar configured for the bot.
- Create tasks in Apps > Tasks. Tasks will be visible in the corresponding calendar.
- Add assignees by entering assignee first names in the Tags section.

## Assignee setup

Assignees are the people who receive task DMs and interact with them in Discord.]

- Join the SAA Discord server.
- Allow DMs from server members for the SAA server.

### What assignees will see

- A DM containing the task details.
- Buttons to accept, cancel, complete, or update a deadline depending on task state.
- Follow-up reminder messages that reference the original task DM.
- Update messages when the task changes.

## Configuration

The user-provided environment variables are:

- `NEXTCLOUD_USER` and `NEXTCLOUD_PASS`: app credentials for the delegator Nextcloud account, generated in account settings.
- `CALENDAR_URL`: URL for target task calendar.
- `USER_MAP_DC`: mapping from task assignee labels to Discord user IDs.
- `REMINDER_DELTAS`: how long before a deadline reminder should be sent (default value set).

To start, run `setup-service.sh` from the stack root with the `--vault-only` and `--skip-env-import` flags set, and follow the instructions. The script will ask for a TLS certificate; your server should have a single vault stack with a certificate. This service configures the Vault Agent and AppRole credentials (see [docs/secrets.md]([url](https://github.com/shahi7/NC-task-notifier/blob/main/docs/secrets.md)) for more details). Run the `vault-operator.sh` script to manually add all required secrets to your desired `VAULT_KV_MOUNT_PATH` (choose the `kv > edit-secrets` workflow) and check to confirm the Vault Agent correctly rendered them. Finally, to start the bot, run `docker compose up --build -d`. 

## Running the system

The system has two long-running responsibilities:

- **Poller**: checks Nextcloud regularly and enqueues work.
- **Bot**: stays connected to Discord and processes queued notifications.

## Error handling

The system is designed to tolerate temporary failures rather than crash and drop work.

### Queue behavior

- New notification jobs are written to a pending queue. Failed jobs move to a “failed” queue and are retried later.
- Update sync jobs from Discord to Nextcloud may fail due to temporary network issues, and are queued to be retried later.

### Common failure cases

This information is useful for delegators and developers when troubleshooting.

| Problem                                             | Likely cause                                                    | What to check                                             |
| --------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------- |
| No DM sent for a new task                           | Assignee mapping missing or empty                               | Confirm `USER_MAP_DC` entry and task assignee label match |
| No DM sent to one user                              | Discord DMs blocked                                             | Check that the assignee allows DMs from the shared server |
| Bot starts but sends nothing                        | Poller not running or queue empty                               | Check poller logs and pending queue files                 |
| Poller runs but finds no changes                    | Sync token issue or wrong calendar                              | Check calendar URL, sync token file, and poller logs      |
| Repeated reminders every run                        | Task incorrectly marked updated or reminder state not persisted | Check stored task state and reminder delta tracking       |
| Update button works in Discord but not in Nextcloud | CALDAV write failure                                            | Check Nextcloud credentials, URL, and update logs         |
| Follow-up jobs keep failing                         | Bot-side message edit/reference problem                         | Check failed queue files and bot logs                     |

### Future Features:

- User-friendly way to add delegators (currently server-side only)
