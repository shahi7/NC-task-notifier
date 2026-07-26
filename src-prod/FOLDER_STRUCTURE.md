# Folder structure

```text
service-template-v2/
├── .env.example
├── .gitlab-ci.yml
├── .gitignore
├── ci/
│   └── README.md
├── config/
├── data/
├── docker-compose.yml
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
