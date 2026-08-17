#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly DEPLOY_CONTRACT_VERSION="3"

: "${STACK_NAME:=}"
: "${DEPLOY_TARGET:=}"
: "${DEPLOY_HOST:=}"
: "${DEPLOY_USER:=}"
: "${DEPLOY_SSH_IDENTITY_FILE:=}"
: "${DEPLOY_SSH_KEY_VAR:=}"
: "${DEPLOY_STACK_PATH:=}"
: "${DEPLOY_ALLOWED_ROOT:=/home/common/stacks}"
: "${DEPLOY_STAGE_ROOT:=/home/common/.ci-staging}"
: "${DEPLOY_RELEASE_ID:=${CI_COMMIT_SHA:-}}"
: "${CI_IMAGE_LOCK_FILE:=ci/approved-images.lock}"
: "${APPROVED_IMAGE_REGISTRY:=}"
: "${DEPLOY_WAIT_TIMEOUT:=180}"
: "${FORCE_REAUTH:=false}"
: "${BOOTSTRAP_SERVICE_STATE:=false}"
: "${SETUP_SERVICE:=false}"
: "${RETAG_TAILSCALE:=false}"

usage() {
  cat <<'EOF'
Usage: deploy-stack-over-ssh.sh [--resolve-context | --preflight]

Deploy a reviewed source release through the versioned remote deployment
contract. The target .env and Vault AppRole files must already exist. This
helper never provisions Vault, transports a Vault parent token, or executes
repository code with Headscale control-plane credentials.
EOF
}

log() { printf '[deploy-stack-over-ssh] %s\n' "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
bool_true() { [[ "${1,,}" =~ ^(1|true|yes|y)$ ]]; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_release() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{6,127}$ ]]; }
valid_registry_prefix() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]; }
valid_absolute_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* && "$1" != */./* ]]
}
valid_relative_path() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != /* && "$1" != *..* && "$1" != */./* ]]
}
path_is_within() {
  local path="${1%/}" root="${2%/}"
  [[ "$path" == "$root/"* ]]
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

read_example_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "${repo_root}/.env.example" 2>/dev/null | sed -n '1p' |
    sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

resolve_context() {
  local namespace target stack_name host_id deploy_host deploy_user deploy_key_var
  namespace="${CI_PROJECT_NAMESPACE:-}"
  target="$DEPLOY_TARGET"
  stack_name="$STACK_NAME"

  [[ -n "$stack_name" ]] || stack_name="$(read_example_value STACK_NAME)"
  [[ -n "$stack_name" ]] || stack_name="$(basename "$repo_root")"

  if [[ -z "$target" ]]; then
    host_id="$(read_example_value HOST_ID)"
    if [[ -n "$host_id" ]]; then
      target="$host_id"
    elif [[ "$namespace" == *"/prime1"* || "$namespace" == prime1* ]]; then
      target="p1"
    elif [[ "$namespace" == *"/zeppelin1"* || "$namespace" == *"/z1"* || "$namespace" == zeppelin1* || "$namespace" == z1* ]]; then
      target="z1"
    fi
  fi

  deploy_host="$DEPLOY_HOST"
  deploy_user="$DEPLOY_USER"
  deploy_key_var="$DEPLOY_SSH_KEY_VAR"
  if [[ -z "$deploy_host" || -z "$deploy_user" || -z "$deploy_key_var" ]]; then
    case "$target" in
      p1|prime1)
        : "${deploy_host:=prime1}"
        : "${deploy_user:=gitlab-p1}"
        : "${deploy_key_var:=SSH_PRIVATE_KEY_P1}"
        ;;
      z1|zeppelin1)
        : "${deploy_host:=zeppelin1.m.onsaa.org}"
        : "${deploy_user:=gitlab-z1}"
        : "${deploy_key_var:=SSH_PRIVATE_KEY_Z1}"
        ;;
      *)
        echo "Set DEPLOY_TARGET=p1|z1 or explicit DEPLOY_HOST, DEPLOY_USER, and DEPLOY_SSH_KEY_VAR." >&2
        exit 1
        ;;
    esac
  fi

  STACK_NAME="$stack_name"
  DEPLOY_TARGET="$target"
  DEPLOY_HOST="$deploy_host"
  DEPLOY_USER="$deploy_user"
  DEPLOY_SSH_KEY_VAR="$deploy_key_var"
}

print_context() {
  printf 'STACK_NAME=%s\n' "$STACK_NAME"
  printf 'DEPLOY_TARGET=%s\n' "$DEPLOY_TARGET"
  printf 'DEPLOY_HOST=%s\n' "$DEPLOY_HOST"
  printf 'DEPLOY_USER=%s\n' "$DEPLOY_USER"
  printf 'DEPLOY_SSH_KEY_VAR=%s\n' "$DEPLOY_SSH_KEY_VAR"
  printf 'DEPLOY_STACK_PATH=%s\n' "$DEPLOY_STACK_PATH"
}

mode="deploy"
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --resolve-context) mode="resolve" ;;
  --preflight) mode="preflight" ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

resolve_context
if [[ "$mode" == "resolve" ]]; then
  valid_name "$STACK_NAME" || { echo "Invalid STACK_NAME." >&2; exit 2; }
  valid_host "$DEPLOY_HOST" || { echo "Invalid DEPLOY_HOST." >&2; exit 2; }
  valid_user "$DEPLOY_USER" || { echo "Invalid DEPLOY_USER." >&2; exit 2; }
  [[ "$DEPLOY_SSH_KEY_VAR" == "SSH_PRIVATE_KEY_P1" || "$DEPLOY_SSH_KEY_VAR" == "SSH_PRIVATE_KEY_Z1" ]] || {
    echo "Invalid DEPLOY_SSH_KEY_VAR." >&2
    exit 2
  }
  valid_absolute_path "$DEPLOY_STACK_PATH" || { echo "DEPLOY_STACK_PATH must be an explicit safe absolute path." >&2; exit 2; }
  valid_absolute_path "$DEPLOY_ALLOWED_ROOT" || { echo "Invalid DEPLOY_ALLOWED_ROOT." >&2; exit 2; }
  path_is_within "$DEPLOY_STACK_PATH" "$DEPLOY_ALLOWED_ROOT" || {
    echo "DEPLOY_STACK_PATH is outside DEPLOY_ALLOWED_ROOT." >&2
    exit 2
  }
  print_context
  exit 0
fi

need_cmd bash
need_cmd git
need_cmd rsync
need_cmd ssh

[[ -z "${VAULT_PARENT_TOKEN:-}" && -z "${VAULT_PARENT_TOKEN_FILE:-}" ]] || {
  echo "Vault parent/bootstrap credentials are forbidden in application deployment." >&2
  exit 2
}
bool_true "$SETUP_SERVICE" && {
  echo "SETUP_SERVICE is not part of the deployment contract; provision Vault separately." >&2
  exit 2
}
bool_true "$RETAG_TAILSCALE" && {
  echo "Headscale retagging requires a separate administrator-owned workflow." >&2
  exit 2
}

valid_name "$STACK_NAME" || { echo "Invalid STACK_NAME." >&2; exit 2; }
valid_host "$DEPLOY_HOST" || { echo "Invalid DEPLOY_HOST." >&2; exit 2; }
valid_user "$DEPLOY_USER" || { echo "Invalid DEPLOY_USER." >&2; exit 2; }
[[ "$DEPLOY_SSH_KEY_VAR" == "SSH_PRIVATE_KEY_P1" || "$DEPLOY_SSH_KEY_VAR" == "SSH_PRIVATE_KEY_Z1" ]] || {
  echo "Invalid DEPLOY_SSH_KEY_VAR." >&2
  exit 2
}
valid_absolute_path "$DEPLOY_ALLOWED_ROOT" || { echo "Invalid DEPLOY_ALLOWED_ROOT." >&2; exit 2; }
valid_absolute_path "$DEPLOY_STAGE_ROOT" || { echo "Invalid DEPLOY_STAGE_ROOT." >&2; exit 2; }
valid_absolute_path "$DEPLOY_STACK_PATH" || { echo "DEPLOY_STACK_PATH must be an explicit safe absolute path." >&2; exit 2; }
path_is_within "$DEPLOY_STACK_PATH" "$DEPLOY_ALLOWED_ROOT" || {
  echo "DEPLOY_STACK_PATH is outside DEPLOY_ALLOWED_ROOT." >&2
  exit 2
}
[[ "$DEPLOY_STACK_PATH" != "$DEPLOY_ALLOWED_ROOT" ]] || { echo "DEPLOY_STACK_PATH cannot equal the allowed root." >&2; exit 2; }
valid_relative_path "$CI_IMAGE_LOCK_FILE" || { echo "Invalid CI_IMAGE_LOCK_FILE." >&2; exit 2; }
valid_registry_prefix "$APPROVED_IMAGE_REGISTRY" || { echo "Invalid APPROVED_IMAGE_REGISTRY." >&2; exit 2; }
[[ "$DEPLOY_WAIT_TIMEOUT" =~ ^[0-9]+$ && "$DEPLOY_WAIT_TIMEOUT" -ge 30 && "$DEPLOY_WAIT_TIMEOUT" -le 900 ]] || {
  echo "DEPLOY_WAIT_TIMEOUT must be between 30 and 900 seconds." >&2
  exit 2
}

[[ -n "$DEPLOY_SSH_IDENTITY_FILE" && -f "$DEPLOY_SSH_IDENTITY_FILE" && ! -L "$DEPLOY_SSH_IDENTITY_FILE" ]] || {
  echo "DEPLOY_SSH_IDENTITY_FILE must be a regular, non-symlink file." >&2
  exit 2
}

for required in \
  docker-compose.yml \
  permissions.tsv \
  scripts/permissions.sh \
  scripts/remote-deploy-release.sh \
  scripts/setup-service.sh \
  scripts/verify-approved-images.sh \
  "$CI_IMAGE_LOCK_FILE"; do
  [[ -f "$repo_root/$required" && ! -L "$repo_root/$required" ]] || {
    echo "Missing required deployment-contract file: $required" >&2
    exit 2
  }
  git -C "$repo_root" ls-files --error-unmatch -- "$required" >/dev/null || {
    echo "Deployment-contract file is not tracked by Git: $required" >&2
    exit 2
  }
done

git -C "$repo_root" diff --quiet -- || { echo "Tracked source has unstaged changes." >&2; exit 2; }
git -C "$repo_root" diff --cached --quiet -- || { echo "Tracked source has staged-but-uncommitted changes." >&2; exit 2; }

while IFS= read -r tracked_path; do
  valid_relative_path "$tracked_path" || {
    echo "Tracked source contains an unsafe path." >&2
    exit 2
  }
  case "$tracked_path" in
    .env.example|runtime/secrets/.gitkeep|runtime/secrets/*/.gitkeep|runtime/vault-auth/.gitkeep|data/*/.gitkeep|backups/.gitkeep)
      ;;
    .env|.env.*|runtime/secrets/*|runtime/vault-auth/*|data/*|backups/*|tls/*|secrets/*)
      echo "Tracked source contains a prohibited runtime/credential path: $tracked_path" >&2
      exit 2
      ;;
  esac
done < <(git -C "$repo_root" ls-files)

contract_version="$(bash "$repo_root/scripts/remote-deploy-release.sh" --version)"
[[ "$contract_version" == "$DEPLOY_CONTRACT_VERSION" ]] || {
  echo "Remote deployment contract version mismatch." >&2
  exit 2
}

if [[ "${CI:-false}" == "true" ]]; then
  valid_release "$DEPLOY_RELEASE_ID" || { echo "CI deployment requires a valid immutable release ID." >&2; exit 2; }
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$DEPLOY_RELEASE_ID" ]] || {
    echo "CI release ID does not match the checked-out commit." >&2
    exit 2
  }
else
  [[ -n "$DEPLOY_RELEASE_ID" ]] || DEPLOY_RELEASE_ID="$(git -C "$repo_root" rev-parse HEAD)"
  valid_release "$DEPLOY_RELEASE_ID" || { echo "Invalid DEPLOY_RELEASE_ID." >&2; exit 2; }
fi

APPROVED_IMAGE_REGISTRY="$APPROVED_IMAGE_REGISTRY" \
  bash "$repo_root/scripts/verify-approved-images.sh" "$repo_root/$CI_IMAGE_LOCK_FILE"

remote_target="${DEPLOY_USER}@${DEPLOY_HOST}"
ssh_args=(
  -i "$DEPLOY_SSH_IDENTITY_FILE"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=6
)

remote_preflight() {
  ssh "${ssh_args[@]}" "$remote_target" bash -s -- "$DEPLOY_STACK_PATH" "$DEPLOY_ALLOWED_ROOT" <<'REMOTE'
set -Eeuo pipefail
stack_path="$1"
allowed_root="$2"

valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* && "$1" != */./* ]]; }
valid_path "$stack_path" && valid_path "$allowed_root" || { echo "Unsafe deployment path." >&2; exit 2; }
[[ "$stack_path" == "${allowed_root%/}/"* && "$stack_path" != "${allowed_root%/}" ]] || {
  echo "Deployment path is outside the allowed root." >&2
  exit 2
}
[[ -d "$stack_path" && ! -L "$stack_path" ]] || { echo "Target stack directory is not pre-provisioned." >&2; exit 1; }

for path in .env runtime/vault-auth/role_id runtime/vault-auth/secret_id; do
  target="$stack_path/$path"
  [[ -f "$target" && ! -L "$target" ]] || { echo "Required target credential/config metadata is missing: $path" >&2; exit 1; }
done

for path in runtime/vault-auth/role_id runtime/vault-auth/secret_id; do
  mode="$(stat -c '%a' "$stack_path/$path")"
  case "$mode" in 400|600) ;; *) echo "Vault auth file mode is not owner-only: $path" >&2; exit 1 ;; esac
done

command -v flock >/dev/null 2>&1 || { echo "Remote flock is required." >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "Remote rsync is required." >&2; exit 1; }
if docker ps >/dev/null 2>&1; then
  :
elif sudo -n docker ps >/dev/null 2>&1; then
  :
else
  echo "Remote deployment identity lacks approved Docker access." >&2
  exit 1
fi

echo "Remote deployment preflight passed."
REMOTE
}

remote_preflight
[[ "$mode" == "preflight" ]] && exit 0

stage_path="${DEPLOY_STAGE_ROOT%/}/${STACK_NAME}-${DEPLOY_RELEASE_ID}"
valid_absolute_path "$stage_path" || { echo "Invalid derived staging path." >&2; exit 2; }
path_is_within "$stage_path" "$DEPLOY_STAGE_ROOT" || { echo "Staging path escaped its root." >&2; exit 2; }

cleanup_remote_stage() {
  ssh "${ssh_args[@]}" "$remote_target" bash -s -- "$stage_path" "$DEPLOY_STAGE_ROOT" <<'REMOTE' >/dev/null 2>&1 || true
set -Eeuo pipefail
stage_path="$1"
stage_root="${2%/}"
[[ "$stage_path" =~ ^/[A-Za-z0-9._/-]+$ && "$stage_path" != *..* ]] || exit 2
[[ "$stage_root" =~ ^/[A-Za-z0-9._/-]+$ && "$stage_root" != *..* ]] || exit 2
[[ "$stage_path" == "$stage_root/"* && "$stage_path" != "$stage_root" ]] || exit 2
rm -rf -- "$stage_path"
REMOTE
}
trap cleanup_remote_stage EXIT

ssh "${ssh_args[@]}" "$remote_target" bash -s -- "$stage_path" "$DEPLOY_STAGE_ROOT" <<'REMOTE'
set -Eeuo pipefail
stage_path="$1"
stage_root="${2%/}"
[[ "$stage_path" =~ ^/[A-Za-z0-9._/-]+$ && "$stage_path" != *..* ]] || exit 2
[[ "$stage_root" =~ ^/[A-Za-z0-9._/-]+$ && "$stage_root" != *..* ]] || exit 2
[[ "$stage_path" == "$stage_root/"* && "$stage_path" != "$stage_root" ]] || exit 2
install -d -m 700 -- "$stage_root"
rm -rf -- "$stage_path"
install -d -m 700 -- "$stage_path"
REMOTE

printf -v rsync_ssh 'ssh'
for ssh_arg in "${ssh_args[@]}"; do
  printf -v quoted_arg '%q' "$ssh_arg"
  rsync_ssh+=" ${quoted_arg}"
done

log "Uploading Git-tracked reviewed source to isolated staging on ${DEPLOY_HOST}."
git -C "$repo_root" ls-files -z |
  rsync -a -r --from0 --files-from=- --relative --omit-dir-times \
    -e "$rsync_ssh" \
    "$repo_root/" \
    "${remote_target}:${stage_path}/"

log "Executing remote deployment contract ${DEPLOY_CONTRACT_VERSION}."
ssh "${ssh_args[@]}" "$remote_target" bash -s -- \
  "$DEPLOY_STACK_PATH" \
  "$stage_path" \
  "$DEPLOY_ALLOWED_ROOT" \
  "$DEPLOY_STAGE_ROOT" \
  "$DEPLOY_RELEASE_ID" \
  "$CI_IMAGE_LOCK_FILE" \
  "$APPROVED_IMAGE_REGISTRY" \
  "$DEPLOY_WAIT_TIMEOUT" \
  "$FORCE_REAUTH" \
  "$BOOTSTRAP_SERVICE_STATE" \
  < "$repo_root/scripts/remote-deploy-release.sh"

trap - EXIT
cleanup_remote_stage
log "Deployment completed through reviewed release ${DEPLOY_RELEASE_ID}."
