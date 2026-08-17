# Folder structure

Updated 2026-07-27 for the nc-taskbot rename and the app/ build context.

`app/` holds application source and is the Docker build context. `images/` holds only `build-map.txt`, which is where the shared CI template looks for the build map; the path is fixed on the CI side, so the two directories cannot be merged.

```text
nc-taskbot/
├── .env.example
├── .gitlab-ci.yml
├── .gitignore
├── app/
│   ├── .dockerignore
│   ├── Dockerfile
│   ├── poller.crontab
│   ├── requirements.txt
│   └── *.py
├── ci/
│   └── README.md
├── config/
├── data/
│   ├── app/
│   ├── signal/
│   └── tailscale/
├── docker-compose.yml
├── images/
│   └── build-map.txt
├── docs/
│   ├── access.md
│   ├── architecture.md
│   ├── opentofu.md
│   ├── operations.md
│   ├── permissions.md
│   ├── recovery.md
│   ├── registry-promotion.md
│   └── secrets.md
├── hooks/
├── opentofu/
├── permissions.tsv
├── runtime/
│   ├── control/
│   ├── secrets/
│   │   ├── bot/
│   │   ├── poller/
│   │   ├── ts-sidecar/
│   │   └── vault-agent/
│   └── vault-auth/
├── scripts/
│   ├── deploy-stack-over-ssh.sh
│   ├── permissions.sh
│   ├── remote-deploy-release.sh
│   ├── setup-service.sh
│   ├── start-tailscale-sidecar.sh
│   ├── start-vault-agent.sh
│   ├── validate-structure.sh
│   └── verify-approved-images.sh
├── tests/
├── tools/
└── vault/
    ├── agent.hcl
    └── templates/
```

Runtime rules:

- CI runs `scripts/validate-structure.sh`: required paths must exist, secret/state dirs (`runtime/secrets`, `runtime/vault-auth`, `runtime/control`, `data`, `backups`) may hold only `.gitkeep`, `.gitignore` must exclude them recursively (`dir/**`, never `dir/*`), and no secret-named or real `.env` file may be tracked.
- Run Compose from the stack root.
- Keep `.env`, `runtime/`, `data/`, backups, TLS material, and credentials out of release staging and source archives.
- Keep `runtime/vault-auth` owner-only; never share it through the application secret-consumer group.
- Production source is owner-writable and infrastructure-admin-group-readable, not group-writable under `nogroup`.
- `ci/approved-images.lock` is intentionally absent until a stack has completed image promotion and administrator review.
