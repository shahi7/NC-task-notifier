# OpenTofu and CI/CD

The `opentofu/` directory is metadata-only. It does not create infrastructure by itself. It records the expected stack shape, Vault paths, networks, bootstrap requirements, and Tailscale deployment model for CI and operators.

`CI_TOFU_APPLY_ENABLED` therefore defaults to `false`. Do not enable it until the stack has reviewed resources, a locking authenticated remote backend, and a state recovery runbook. When enabled, apply consumes the exact checksummed plan artifact; it never creates a second plan after approval.

## What CI runs

1. `compose:validate`
2. GitLab SAST jobs
3. `opentofu:fmt`
4. `opentofu:validate`
5. `opentofu:plan`
6. `image-lock:validate` when deployment is enabled
7. `deploy:preflight` as a commit-bound manual job
8. `deploy:apply` as a serialized staged release transaction
9. `opentofu:apply` only after real resources and state are separately enabled

## Local OpenTofu validation

```bash
cd opentofu
tofu init -backend=false
tofu fmt -check -recursive
tofu validate
tofu plan
```

`opentofu/tofu.auto.tfvars.example` is sufficient for the current metadata-only package. A real stateful configuration requires a separately reviewed backend.

## Required protected CI variables

```text
DEPLOY_TARGET=p1|z1
DEPLOY_STACK_PATH=/home/common/stacks/<approved-stack>
SSH_PRIVATE_KEY_P1
SSH_PRIVATE_KEY_Z1
SSH_KNOWN_HOSTS
CI_DEPLOY_APPROVED_SHA
CI_IMAGE_PROMOTION_APPROVED_SHA
```

Use GitLab file-type variables for SSH keys and known hosts. The application deployment pipeline must never receive a Vault parent/bootstrap token. An administrator must provision the target `.env` and `runtime/vault-auth` files before deployment is enabled.

Optional protected overrides are:

```text
DEPLOY_HOST
DEPLOY_USER
DEPLOY_SSH_KEY_VAR
DEPLOY_ALLOWED_ROOT=/home/common/stacks
DEPLOY_STAGE_ROOT=/home/common/.ci-staging
DEPLOY_WAIT_TIMEOUT=180
FORCE_REAUTH=false
BOOTSTRAP_SERVICE_STATE=false
```

The target host can be inferred from `DEPLOY_TARGET`, but `DEPLOY_STACK_PATH` is always explicit. Namespace inference must never choose a production filesystem path.

## Deployment contract

`deploy:apply` uses `scripts/deploy-stack-over-ssh.sh` and `scripts/remote-deploy-release.sh`. Together they:

1. verify the versioned deploy contract and explicit target allowlist
2. require an existing `.env` and owner-only AppRole files without reading them
3. upload reviewed source to a mode-0700 staging directory
4. compare the production-rendered image set with the approved image lock
5. pre-pull images, acquire a per-stack lock, and snapshot non-secret source
6. publish with exclusions protecting `.env`, runtime, data, backups, and TLS
7. reapply and validate the declared source/runtime permission manifest
8. revalidate the image lock and Compose model after publish
9. run Compose with `--wait` without a prior `compose down`
10. record the release/image-lock digest and restore prior source on failure

Vault provisioning and Headscale retagging are separate administrator-owned workflows. A stack repository must not execute its own code using Headscale control-plane credentials.

## GitLab approval model

Deployment remains disabled by default. Before enabling it:

1. protect the default branch and require reviewed merge requests
2. set the minimum role for pipeline-variable overrides to `no_one_allowed`
3. keep target, SSH, registry, and approval variables protected
4. set both approval variables to the exact reviewed commit
5. use a dedicated protected runner with no production Docker socket/API
6. configure the production resource group as `newest_ready_first`

On GitLab CE, YAML variables are not a complete administrator-approval boundary. Use a separate administrator-owned deployment project and runner; only that project may hold production credentials or set approval SHAs. Premium/Ultimate installations can additionally configure protected-environment deployment approval rules.

The current OpenTofu package does not deploy Compose resources. Implementing real stateful infrastructure deployment through OpenTofu remains an explicit work item; do not disguise SSH shell deployment as a Terraform resource.
