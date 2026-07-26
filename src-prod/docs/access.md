# Access

Services are private by default.

## Default Access

Use the Tailnet route:

```text
https://<service>.m.onsaa.org
```

Traefik receives the request on `tailsecure` and forwards it to the Tailscale sidecar, which shares its network namespace with the app.

## Public Access

`websecure` labels are present but commented out in `docker-compose.yml`. Uncomment them only for services that are intentionally public.
