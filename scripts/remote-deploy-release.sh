#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly DEPLOY_CONTRACT_VERSION="3"

if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "$DEPLOY_CONTRACT_VERSION"
  exit 0
fi

if [[ "$#" -ne 10 ]]; then
  echo "Remote deployment contract requires exactly 10 arguments." >&2
  exit 2
fi

live_path="${1%/}"
stage_path="${2%/}"
allowed_root="${3%/}"
stage_root="${4%/}"
release_id="$5"
image_lock_rel="$6"
approved_registry="${7%/}"
wait_timeout="$8"
force_reauth="$9"
bootstrap_service_state="${10}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Remote deployment requires $1." >&2; exit 1; }; }
bool_true() { [[ "${1,,}" =~ ^(1|true|yes|y)$ ]]; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
valid_release() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{6,127}$ ]]; }
valid_registry_prefix() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]; }
valid_absolute_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* && "$1" != */./* ]]; }
valid_relative_path() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != /* && "$1" != *..* && "$1" != */./* ]]; }
path_is_within() { [[ "${1%/}" == "${2%/}/"* ]]; }

for cmd in awk bash flock rsync sha256sum stat; do need_cmd "$cmd"; done
valid_absolute_path "$live_path" || { echo "Unsafe live path." >&2; exit 2; }
valid_absolute_path "$stage_path" || { echo "Unsafe staging path." >&2; exit 2; }
valid_absolute_path "$allowed_root" || { echo "Unsafe allowed root." >&2; exit 2; }
valid_absolute_path "$stage_root" || { echo "Unsafe staging root." >&2; exit 2; }
path_is_within "$live_path" "$allowed_root" || { echo "Live path escaped allowed root." >&2; exit 2; }
path_is_within "$stage_path" "$stage_root" || { echo "Staging path escaped staging root." >&2; exit 2; }
[[ "$live_path" != "$allowed_root" && "$stage_path" != "$stage_root" ]] || { echo "Refusing a root directory as a deployment target." >&2; exit 2; }
valid_release "$release_id" || { echo "Invalid release ID." >&2; exit 2; }
valid_relative_path "$image_lock_rel" || { echo "Invalid image-lock path." >&2; exit 2; }
valid_registry_prefix "$approved_registry" || { echo "Invalid approved registry." >&2; exit 2; }
[[ "$wait_timeout" =~ ^[0-9]+$ && "$wait_timeout" -ge 30 && "$wait_timeout" -le 900 ]] || { echo "Invalid deployment wait timeout." >&2; exit 2; }

stack_name="$(basename "$live_path")"
valid_name "$stack_name" || { echo "Invalid target stack name." >&2; exit 2; }
[[ -d "$live_path" && ! -L "$live_path" ]] || { echo "Live stack must be pre-provisioned." >&2; exit 1; }
[[ -d "$stage_path" && ! -L "$stage_path" ]] || { echo "Staged release is missing." >&2; exit 1; }

for path in \
  "$live_path/.env" \
  "$live_path/runtime/vault-auth/role_id" \
  "$live_path/runtime/vault-auth/secret_id" \
  "$stage_path/docker-compose.yml" \
  "$stage_path/permissions.tsv" \
  "$stage_path/$image_lock_rel" \
  "$stage_path/scripts/permissions.sh" \
  "$stage_path/scripts/setup-service.sh" \
  "$stage_path/scripts/verify-approved-images.sh"; do
  [[ -f "$path" && ! -L "$path" ]] || { echo "Deployment contract file is missing or unsafe." >&2; exit 1; }
done

for path in "$live_path/runtime/vault-auth/role_id" "$live_path/runtime/vault-auth/secret_id"; do
  mode="$(stat -c '%a' "$path")"
  case "$mode" in 400|600) ;; *) echo "Vault auth file is not owner-only." >&2; exit 1 ;; esac
done

docker_cmd=()
if docker ps >/dev/null 2>&1; then
  docker_cmd=(docker)
elif sudo -n docker ps >/dev/null 2>&1; then
  docker_cmd=(sudo -n docker)
else
  echo "Remote deployment identity lacks approved Docker access." >&2
  exit 1
fi

compose_stage=("${docker_cmd[@]}" compose --env-file "$live_path/.env" -f "$stage_path/docker-compose.yml")
compose_live=("${docker_cmd[@]}" compose --env-file "$live_path/.env" -f "$live_path/docker-compose.yml")

install -d -m 700 -- "$stage_root/.locks" "$stage_root/.rollback"
lock_key="$(printf '%s' "$live_path" | sha256sum | awk '{print $1}')"
exec 9>"$stage_root/.locks/${lock_key}.lock"
flock -n 9 || { echo "Another deployment is active for this stack." >&2; exit 1; }

rollback_dir="$stage_root/.rollback/$stack_name/$release_id"
deploy_meta="$live_path/.deploy"
publish_started=0
keep_stage=0

sync_filters=(
  --include='/.env.example'
  --exclude='/.env*'
  --exclude='/.git/'
  --exclude='/.deploy/'
  --exclude='/backups/'
  --exclude='/data/'
  --exclude='/runtime/'
  --exclude='/secrets/'
  --exclude='/tls/'
)

cleanup() {
  if [[ "$keep_stage" -eq 0 && -d "$stage_path" && "$stage_path" == "$stage_root/"* ]]; then
    rm -rf -- "$stage_path"
  fi
}

rollback() {
  local original_rc="$?" rollback_rc=0
  trap - ERR
  set +e
  if [[ "$publish_started" -eq 1 && -d "$rollback_dir/source" ]]; then
    echo "Deployment failed; restoring the previous reviewed source." >&2
    rsync -a --delete-delay "${sync_filters[@]}" "$rollback_dir/source/" "$live_path/" || rollback_rc=1
    if [[ "$rollback_rc" -eq 0 && -f "$live_path/docker-compose.yml" ]]; then
      "${docker_cmd[@]}" compose --env-file "$live_path/.env" -f "$live_path/docker-compose.yml" \
        up -d --force-recreate --remove-orphans --wait --wait-timeout "$wait_timeout" || rollback_rc=1
    fi
    if [[ -f "$deploy_meta/previous-release" ]]; then
      cp -f -- "$deploy_meta/previous-release" "$deploy_meta/current-release" || rollback_rc=1
    fi
  fi
  if [[ "$rollback_rc" -ne 0 ]]; then
    keep_stage=1
    echo "Automatic rollback failed; staged and rollback source were retained for an administrator." >&2
  else
    echo "Live source was unchanged or automatic rollback completed." >&2
  fi
  exit "$original_rc"
}

trap cleanup EXIT
trap rollback ERR

APPROVED_IMAGE_REGISTRY="$approved_registry" \
  bash "$stage_path/scripts/verify-approved-images.sh" \
    "$stage_path/$image_lock_rel" "$live_path/.env" "$stage_path/docker-compose.yml"
"${compose_stage[@]}" config --quiet
"${compose_stage[@]}" pull --quiet

rm -rf -- "$rollback_dir"
install -d -m 700 -- "$rollback_dir/source"
rsync -a "${sync_filters[@]}" "$live_path/" "$rollback_dir/source/"

install -d -m 700 -- "$deploy_meta"
if [[ -f "$deploy_meta/current-release" && ! -L "$deploy_meta/current-release" ]]; then
  cp -f -- "$deploy_meta/current-release" "$deploy_meta/previous-release"
  chmod 600 "$deploy_meta/previous-release"
fi

publish_started=1
rsync -a --delete-delay "${sync_filters[@]}" "$stage_path/" "$live_path/"

APPROVED_IMAGE_REGISTRY="$approved_registry" \
  bash "$live_path/scripts/verify-approved-images.sh" \
    "$live_path/$image_lock_rel" "$live_path/.env" "$live_path/docker-compose.yml"
"${compose_live[@]}" config --quiet
bash "$live_path/scripts/setup-service.sh" --bootstrap-only -y
bash "$live_path/scripts/permissions.sh" apply \
  --root "$live_path" --manifest "$live_path/permissions.tsv"
bash "$live_path/scripts/permissions.sh" check \
  --root "$live_path" --manifest "$live_path/permissions.tsv"

if bool_true "$bootstrap_service_state"; then
  hook="$live_path/hooks/bootstrap-service-state.sh"
  [[ -f "$hook" && ! -L "$hook" ]] || { echo "Requested service bootstrap hook is missing or unsafe." >&2; false; }
  bash "$hook"
fi

if bool_true "$force_reauth"; then
  install -d -m 700 -- "$live_path/runtime/control"
  : > "$live_path/runtime/control/tailscale-force-reauth"
  chmod 600 "$live_path/runtime/control/tailscale-force-reauth"
fi

"${compose_live[@]}" up -d --force-recreate --remove-orphans --wait --wait-timeout "$wait_timeout"
"${compose_live[@]}" ps

lock_digest="$(sha256sum "$live_path/$image_lock_rel" | awk '{print $1}')"
{
  printf 'release=%s\n' "$release_id"
  printf 'image_lock_sha256=%s\n' "$lock_digest"
} > "$deploy_meta/current-release"
chmod 600 "$deploy_meta/current-release"

publish_started=0
echo "Remote release deployment passed validation and health gates."
