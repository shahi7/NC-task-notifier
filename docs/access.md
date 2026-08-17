# Access

Services are private by default. This one has no inbound route at all.

## Default Access

There is nothing to browse to. The bot and poller only make outbound calls, so operating the service means reaching the host and using Docker:

```text
docker compose logs -f bot
docker compose logs -f poller
docker compose ps
```

Users interact with the service through Discord, not through a URL. Delegators assign tasks in Nextcloud and run `/add_user` in Discord; assignees receive DMs.

## Tailnet Access

The Tailscale sidecar and its `tailsecure` router live behind the optional `tailnet` Compose profile and are not started by default. They only become relevant if something in this stack is ever given an HTTP listener. See [architecture.md](architecture.md).

## Public Access

`websecure` labels are present but commented out in `docker-compose.yml`. Uncomment them only for services that are intentionally public. Nothing here should be.
