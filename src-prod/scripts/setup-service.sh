#!/usr/bin/env bash
# service setup: runtime folders, Vault policy/AppRole, auth files, optional KV import and authkey

set -Eeuo pipefail
set +x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INITIAL_ENV_KEYS="$(env | sed 's/=.*//' | sort -u)"

: "${CONTROLS_ENV:=/home/common/config/controls.env}"
: "${SERVICE_ENV:=${REPO_ROOT}/.env}"
: "${EDITOR:=nano}"

TMP_FILES=()
PARENT_TOKEN=""
curl_opts=()
MODE="all"
YES=0
SKIP_ENV_IMPORT=0
IMPORT_ENV=0
SKIP_AUTHKEY=0

cleanup() {
  local f
  unset PARENT_TOKEN
  for f in "${TMP_FILES[@]:-}"; do
    if [ -n "${f:-}" ] && [ -e "$f" ]; then
      rm -f -- "$f" || true
    fi
  done
  return 0
}
trap cleanup EXIT INT TERM

usage() {
  cat <<USAGE
Usage: ./scripts/setup-service.sh [options]

Options:
  --bootstrap-only       Only create local runtime folders and permissions.
  --vault-only           Bootstrap and configure Vault, but skip authkey generation.
  --skip-env-import      Do not offer to import non-platform .env values to Vault.
  --import-env           Import non-platform .env values without prompting.
  --skip-authkey         Do not offer to generate/store a Headscale authkey.
  -y, --yes              Accept safe defaults where possible.
  -h, --help             Show this help.

Default mode runs bootstrap, Vault setup, optional .env import, and optional authkey generation.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bootstrap-only) MODE="bootstrap" ;;
    --vault-only) MODE="vault"; SKIP_AUTHKEY=1 ;;
    --skip-env-import) SKIP_ENV_IMPORT=1 ;;
    --import-env) IMPORT_ENV=1 ;;
    --skip-authkey) SKIP_AUTHKEY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
has_whiptail() { [ -t 0 ] && command -v whiptail >/dev/null 2>&1; }
has_dialog() { [ -t 0 ] && command -v dialog >/dev/null 2>&1; }
mk_tmp() { local f; f="$(mktemp)"; TMP_FILES+=("$f"); printf '%s' "$f"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_quotes() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then
    s="${s:1:${#s}-2}"
  elif [[ "$s" == \'*\' && "$s" == *\' ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

caller_set() { grep -qx -- "$1" <<< "$INITIAL_ENV_KEYS"; }

load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == export\ * ]] && line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    caller_set "$key" && continue
    value="$(strip_quotes "$value")"
    export "$key=$value"
  done < "$file"
}

load_env_file "$CONTROLS_ENV"
load_env_file "$SERVICE_ENV"

# host-side Vault API settings stay separate from container-side Vault Agent settings
: "${STACK_NAME:=$(basename "$REPO_ROOT")}"
: "${APP_CONTAINER_PORT:=80}"
: "${VAULT_ADDR:=https://vault:8200}"
: "${VAULT_API_ADDR:=${MAIN_VAULT_ADDR:-https://127.0.0.1:8200}}"
: "${VAULT_API_CACERT:=${HOST_VAULT_CA_CERT:-}}"
: "${VAULT_SKIP_VERIFY:=false}"
: "${VAULT_KV_PATH:=kv/data/${STACK_NAME}}"
: "${VAULT_KV_VERSION:=2}"
: "${APPROLE_MOUNT:=approle}"
: "${VAULT_APPROLE_NAME:=${STACK_NAME}}"
: "${VAULT_POLICY_NAME:=app-${STACK_NAME}-read-kv}"
: "${VAULT_APPROLE_TOKEN_TTL:=1h}"
: "${VAULT_APPROLE_TOKEN_MAX_TTL:=24h}"
: "${VAULT_APPROLE_SECRET_ID_TTL:=0}"
: "${VAULT_APPROLE_SECRET_ID_USES:=0}"
: "${HEADSCALE_CONTAINER:=headscale}"
: "${HEADSCALE_USER:=}"
: "${TS_TAG:=tag:container}"
: "${TS_AUTHKEY_EXPIRATION:=24h}"
: "${TS_AUTHKEY_REUSABLE:=false}"
: "${TS_AUTHKEY_EPHEMERAL:=false}"

VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
VAULT_SECRET_NAME="${STACK_NAME}"

ui_msg() {
  local title="$1" msg="$2"
  msg="$(printf '%b' "$msg")"
  if has_whiptail; then
    whiptail --title "$title" --msgbox "$msg" 16 86
  elif has_dialog; then
    dialog --title "$title" --msgbox "$msg" 16 86
    clear || true
  else
    printf '\n%s\n%s\n\n' "$title" "$msg"
  fi
  return 0
}

ui_input() {
  local title="$1" msg="$2" default="${3:-}" value=""
  if [ "$YES" -eq 1 ]; then printf '%s' "$default"; return 0; fi
  if has_whiptail; then
    value="$(whiptail --title "$title" --inputbox "$msg" 10 86 "$default" 3>&1 1>&2 2>&3)" || return 1
  elif has_dialog; then
    value="$(dialog --title "$title" --inputbox "$msg" 10 86 "$default" 3>&1 1>&2 2>&3)" || return 1
    clear || true
  else
    read -r -p "$msg [$default]: " value < /dev/tty
    value="${value:-$default}"
  fi
  printf '%s' "$value"
}

ui_secret() {
  local title="$1" msg="$2" value=""
  if [ -n "${VAULT_TOKEN_FILE:-}" ]; then
    [ -r "$VAULT_TOKEN_FILE" ] || { echo "Vault token file is not readable: $VAULT_TOKEN_FILE" >&2; exit 2; }
    tr -d '\r\n' < "$VAULT_TOKEN_FILE"
    return 0
  fi
  if has_whiptail; then
    value="$(whiptail --title "$title" --passwordbox "$msg" 10 86 3>&1 1>&2 2>&3)" || return 1
  elif has_dialog; then
    value="$(dialog --title "$title" --passwordbox "$msg" 10 86 3>&1 1>&2 2>&3)" || return 1
    clear || true
  else
    printf '%s\n' "Install whiptail or dialog, or set VAULT_TOKEN_FILE, for hidden token entry." >&2
    exit 1
  fi
  printf '%s' "$value"
}

ui_yesno() {
  local title="$1" msg="$2" default="${3:-yes}" rc answer prompt
  if [ "$YES" -eq 1 ]; then [ "$default" = "yes" ]; return $?; fi
  if has_whiptail; then
    if [ "$default" = "no" ]; then
      whiptail --title "$title" --defaultno --yesno "$msg" 16 86
    else
      whiptail --title "$title" --yesno "$msg" 16 86
    fi
    return $?
  elif has_dialog; then
    if [ "$default" = "no" ]; then
      dialog --title "$title" --defaultno --yesno "$msg" 16 86
    else
      dialog --title "$title" --yesno "$msg" 16 86
    fi
    rc=$?
    clear || true
    return "$rc"
  fi
  [ "$default" = "no" ] && prompt="y/N" || prompt="Y/n"
  while true; do
    read -r -p "$msg [$prompt]: " answer < /dev/tty
    answer="${answer:-$default}"
    case "$answer" in y|Y|yes|YES) return 0 ;; n|N|no|NO) return 1 ;; esac
  done
}

normalize_bool() { case "${1,,}" in 1|true|yes|y) return 0 ;; *) return 1 ;; esac; }
valid_stack_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
valid_vault_name() { [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]; }
valid_duration() { [[ "$1" == "0" || "$1" =~ ^[0-9]+[smhd]?$ ]]; }
normalize_duration() {
  local v="${1// /}"
  valid_duration "$v" || { echo "Invalid duration: $1" >&2; exit 2; }
  if [[ "$v" =~ ^[0-9]+$ && "$v" != "0" ]]; then printf '%sh' "$v"; else printf '%s' "$v"; fi
}

bootstrap_runtime() {
  mkdir -p \
    "$REPO_ROOT/config" \
    "$REPO_ROOT/data/app" \
    "$REPO_ROOT/data/tailscale" \
    "$REPO_ROOT/runtime/control" \
    "$REPO_ROOT/runtime/secrets" \
    "$REPO_ROOT/runtime/secrets/bot" \
    "$REPO_ROOT/runtime/secrets/poller" \
    "$REPO_ROOT/runtime/secrets/ts-sidecar" \
    "$REPO_ROOT/runtime/secrets/vault-agent" \
    "$REPO_ROOT/runtime/vault-auth" \
    "$REPO_ROOT/backups"

  touch \
    "$REPO_ROOT/data/app/.gitkeep" \
    "$REPO_ROOT/data/tailscale/.gitkeep" \
    "$REPO_ROOT/runtime/control/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/bot/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/poller/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/ts-sidecar/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/vault-agent/.gitkeep" \
    "$REPO_ROOT/runtime/vault-auth/.gitkeep" \
    "$REPO_ROOT/backups/.gitkeep"

  chmod 700 \
    "$REPO_ROOT/runtime" \
    "$REPO_ROOT/runtime/control" \
    "$REPO_ROOT/runtime/secrets" \
    "$REPO_ROOT/runtime/vault-auth" \
    "$REPO_ROOT/backups" 2>/dev/null || true
  chmod 2750 \
    "$REPO_ROOT/runtime/secrets/bot" \
    "$REPO_ROOT/runtime/secrets/poller" \
    "$REPO_ROOT/runtime/secrets/ts-sidecar" \
    "$REPO_ROOT/runtime/secrets/vault-agent" 2>/dev/null || true
  chmod 600 \
    "$REPO_ROOT/runtime/control/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/.gitkeep" \
    "$REPO_ROOT/runtime/vault-auth/.gitkeep" \
    "$REPO_ROOT/backups/.gitkeep" 2>/dev/null || true
  chmod 640 \
    "$REPO_ROOT/runtime/secrets/bot/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/poller/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/ts-sidecar/.gitkeep" \
    "$REPO_ROOT/runtime/secrets/vault-agent/.gitkeep" 2>/dev/null || true
}

refresh_curl_opts() {
  curl_opts=(-sS --connect-timeout 5 --max-time 60)
  if normalize_bool "$VAULT_SKIP_VERIFY"; then
    curl_opts+=(-k)
  elif [ -n "${VAULT_API_CACERT:-}" ]; then
    [ -f "$VAULT_API_CACERT" ] || { echo "VAULT_API_CACERT does not exist: $VAULT_API_CACERT" >&2; exit 2; }
    curl_opts+=(--cacert "$VAULT_API_CACERT")
  fi
}

return_vault_error() {
  local method="$1" path="$2" err_file="$3"
  echo "Vault API request failed: $method /v1/${path#/}" >&2
  [ -s "$err_file" ] && printf 'curl: %s\n' "$(tr '\n' ' ' < "$err_file")" >&2
  echo "Hint: check VAULT_API_ADDR, VAULT_API_CACERT, and VAULT_SKIP_VERIFY." >&2
  return 1
}

vault_api() {
  local method="$1" path="$2" body_file="${3:-}" url response http body err_file
  err_file="$(mk_tmp)"
  url="${VAULT_API_ADDR%/}/v1/${path#/}"
  if [ -n "$body_file" ]; then
    response="$(curl "${curl_opts[@]}" -w $'\n%{http_code}' -K - -X "$method" --data-binary "@$body_file" "$url" 2>"$err_file" <<CURLCFG
header = "X-Vault-Token: ${PARENT_TOKEN}"
header = "Content-Type: application/json"
${VAULT_NAMESPACE:+header = "X-Vault-Namespace: ${VAULT_NAMESPACE}"}
CURLCFG
)" || return_vault_error "$method" "$path" "$err_file"
  else
    response="$(curl "${curl_opts[@]}" -w $'\n%{http_code}' -K - -X "$method" "$url" 2>"$err_file" <<CURLCFG
header = "X-Vault-Token: ${PARENT_TOKEN}"
header = "Content-Type: application/json"
${VAULT_NAMESPACE:+header = "X-Vault-Namespace: ${VAULT_NAMESPACE}"}
CURLCFG
)" || return_vault_error "$method" "$path" "$err_file"
  fi
  http="${response##*$'\n'}"
  body="${response%$'\n'"$http"}"
  if [[ ! "$http" =~ ^2[0-9][0-9]$ ]]; then
    echo "Vault API returned HTTP $http for $method /v1/${path#/}" >&2
    [ -n "$body" ] && printf '%s\n' "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

vault_api_noauth() {
  local method="$1" path="$2" url response http body err_file
  err_file="$(mk_tmp)"
  url="${VAULT_API_ADDR%/}/v1/${path#/}"
  response="$(curl "${curl_opts[@]}" -w $'\n%{http_code}' -X "$method" "$url" 2>"$err_file")" || return_vault_error "$method" "$path" "$err_file"
  http="${response##*$'\n'}"
  body="${response%$'\n'"$http"}"
  if [[ ! "$http" =~ ^2[0-9][0-9]$ ]]; then
    echo "Vault API returned HTTP $http for $method /v1/${path#/}" >&2
    [ -n "$body" ] && printf '%s\n' "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

parse_kv_path() {
  if [[ "$VAULT_KV_PATH" =~ ^([^/]+)/data/(.+)$ ]]; then
    VAULT_KV_MOUNT="${BASH_REMATCH[1]}"
    VAULT_SECRET_NAME="${BASH_REMATCH[2]}"
    VAULT_KV_VERSION="2"
  else
    echo "Invalid VAULT_KV_PATH: $VAULT_KV_PATH" >&2
    echo "This template expects a KV v2 API path like kv/data/<service-name>." >&2
    exit 2
  fi
}

kv_data_api_path() { printf '%s/data/%s' "$VAULT_KV_MOUNT" "$VAULT_SECRET_NAME"; }
kv_metadata_path() { printf '%s/metadata/%s' "$VAULT_KV_MOUNT" "$VAULT_SECRET_NAME"; }

policy_file() {
  local f data meta
  f="$(mk_tmp)"
  data="$(kv_data_api_path)"
  meta="$(kv_metadata_path)"
  cat > "$f" <<POLICY
path "${data}" {
  capabilities = ["read"]
}

path "${meta}" {
  capabilities = ["read", "list"]
}
POLICY
  printf '%s' "$f"
}

prompt_parent_token() {
  PARENT_TOKEN="$(ui_secret "Vault token" "Paste a privileged Vault token that can write policies, AppRoles, and ${VAULT_KV_PATH}.")"
  PARENT_TOKEN="${PARENT_TOKEN//$'\r'/}"
  PARENT_TOKEN="${PARENT_TOKEN//$'\n'/}"
  [ -n "$PARENT_TOKEN" ] || { echo "Empty Vault token." >&2; exit 2; }
  vault_api GET auth/token/lookup-self >/dev/null || { echo "Vault token lookup failed." >&2; exit 1; }
}

write_policy_and_approle() {
  local hcl payload role_payload token_ttl token_max_ttl secret_id_ttl uses
  hcl="$(policy_file)"
  payload="$(mk_tmp)"
  jq -Rs '{policy:.}' < "$hcl" > "$payload"
  vault_api PUT "sys/policies/acl/${VAULT_POLICY_NAME}" "$payload" >/dev/null

  token_ttl="$(normalize_duration "$VAULT_APPROLE_TOKEN_TTL")"
  token_max_ttl="$(normalize_duration "$VAULT_APPROLE_TOKEN_MAX_TTL")"
  secret_id_ttl="$(normalize_duration "$VAULT_APPROLE_SECRET_ID_TTL")"
  uses="$VAULT_APPROLE_SECRET_ID_USES"
  [[ "$uses" =~ ^[0-9]+$ ]] || { echo "Invalid VAULT_APPROLE_SECRET_ID_USES: $uses" >&2; exit 2; }

  role_payload="$(mk_tmp)"
  jq -n \
    --arg policy "$VAULT_POLICY_NAME" \
    --arg token_ttl "$token_ttl" \
    --arg token_max_ttl "$token_max_ttl" \
    --arg secret_id_ttl "$secret_id_ttl" \
    --argjson secret_id_num_uses "$uses" \
    '{
      bind_secret_id:true,
      token_type:"service",
      token_num_uses:0,
      token_policies:[$policy],
      token_ttl:$token_ttl,
      token_max_ttl:$token_max_ttl,
      token_explicit_max_ttl:$token_max_ttl,
      secret_id_ttl:$secret_id_ttl,
      secret_id_num_uses:$secret_id_num_uses
    }' > "$role_payload"

  vault_api POST "auth/${APPROLE_MOUNT}/role/${VAULT_APPROLE_NAME}" "$role_payload" >/dev/null
}

write_local_approle_files() {
  local response role_id secret_id auth_dir="$REPO_ROOT/runtime/vault-auth" role_tmp secret_tmp
  response="$(vault_api GET "auth/${APPROLE_MOUNT}/role/${VAULT_APPROLE_NAME}/role-id")"
  role_id="$(printf '%s' "$response" | jq -r '.data.role_id')"
  response="$(vault_api POST "auth/${APPROLE_MOUNT}/role/${VAULT_APPROLE_NAME}/secret-id")"
  secret_id="$(printf '%s' "$response" | jq -r '.data.secret_id')"
  if [ -z "$role_id" ] || [ "$role_id" = "null" ]; then
    echo "Failed to read role_id." >&2
    exit 1
  fi
  if [ -z "$secret_id" ] || [ "$secret_id" = "null" ]; then
    echo "Failed to generate secret_id." >&2
    exit 1
  fi

  mkdir -p "$auth_dir"
  chmod 700 "$REPO_ROOT/runtime" "$auth_dir" 2>/dev/null || true
  umask 077
  role_tmp="$(mktemp "$auth_dir/.role_id.XXXXXX")"
  secret_tmp="$(mktemp "$auth_dir/.secret_id.XXXXXX")"
  TMP_FILES+=("$role_tmp" "$secret_tmp")
  printf '%s\n' "$role_id" > "$role_tmp"
  printf '%s\n' "$secret_id" > "$secret_tmp"
  chmod 400 "$role_tmp" "$secret_tmp"
  mv -f -- "$role_tmp" "$auth_dir/role_id"
  mv -f -- "$secret_tmp" "$auth_dir/secret_id"
}

read_secret_json() {
  local response
  if response="$(vault_api GET "$(kv_data_api_path)" 2>/dev/null)"; then
    printf '%s' "$response" | jq -c '.data.data // {}'
  else
    printf '{}'
  fi
}

write_secret_json() {
  local data_json="$1" payload
  payload="$(mk_tmp)"
  jq -n --argjson data "$data_json" '{data:$data}' > "$payload"
  vault_api POST "$(kv_data_api_path)" "$payload" >/dev/null
}

merge_secret_json() {
  local new_json="$1" existing merged
  existing="$(read_secret_json)"
  merged="$(jq -cn --argjson a "$existing" --argjson b "$new_json" '$a + $b')"
  write_secret_json "$merged"
}

env_import_json() {
  local file="$1" line key value lower json="{}"
  [ -f "$file" ] || { printf '{}'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    [[ "$line" == export\ * ]] && line="${line#export }"
    key="$(trim "${line%%=*}")"
    value="$(strip_quotes "$(trim "${line#*=}")")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$key" in
      STACK_NAME|APP_IMAGE|APP_CONTAINER_PORT|APP_FQDN|APP_PUBLIC_FQDN|TRAEFIK_*|TAILSECURE_*|WEBSECURE_*|TAILSCALE_VERSION|TS_*|VAULT_*|HOST_VAULT_CA_CERT|APPROLE_MOUNT|HEADSCALE_*|CONTROLS_ENV|SERVICE_ENV)
        continue ;;
    esac
    lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    json="$(printf '%s' "$json" | jq --arg k "$lower" --arg v "$value" '. + {($k): $v}')"
  done < "$file"
  printf '%s' "$json"
}

headscale_exec() { docker exec "$HEADSCALE_CONTAINER" headscale "$@"; }

headscale_authkey() {
  local help output key
  need_cmd docker
  docker ps --format '{{.Names}}' | grep -Fxq "$HEADSCALE_CONTAINER" || {
    echo "Headscale container '$HEADSCALE_CONTAINER' is not running." >&2
    return 1
  }

  help="$(headscale_exec preauthkeys create --help 2>&1 || true)"
  [[ "$HEADSCALE_USER" =~ ^[0-9]+$ ]] || {
    echo "HEADSCALE_USER must be the numeric Headscale user ID." >&2
    return 2
  }

  local -a cmd=(--force preauthkeys create)
  grep -q -- '--user' <<< "$help" && cmd+=(--user "$HEADSCALE_USER")
  grep -q -- '--expiration' <<< "$help" && cmd+=(--expiration "$TS_AUTHKEY_EXPIRATION")
  normalize_bool "$TS_AUTHKEY_REUSABLE" && cmd+=(--reusable)
  normalize_bool "$TS_AUTHKEY_EPHEMERAL" && cmd+=(--ephemeral)
  if [ -n "${TS_TAG:-}" ] && grep -q -- '--tags' <<< "$help"; then
    cmd+=(--tags "$TS_TAG")
  fi

  # Current Headscale emits the new key on stderr in human output mode.
  output="$(headscale_exec "${cmd[@]}" 2>&1)" || return 1
  key="$(printf '%s\n' "$output" | grep -Eo '(hskey|tskey)-auth-[A-Za-z0-9_-]+' | head -n1 || true)"
  [ -n "$key" ] || return 1
  printf '%s' "$key"
}

maybe_generate_authkey() {
  local key
  [ "$SKIP_AUTHKEY" -eq 1 ] && return 0
  ui_yesno "Headscale authkey" "Generate/store a Headscale authkey in Vault as tailscale_authkey?" "yes" || return 0

  HEADSCALE_CONTAINER="$(ui_input "Headscale container" "Docker container running Headscale" "$HEADSCALE_CONTAINER")"
  HEADSCALE_USER="$(ui_input "Headscale user ID" "Numeric Headscale user ID for preauth key" "$HEADSCALE_USER")"
  TS_AUTHKEY_EXPIRATION="$(ui_input "Authkey expiration" "Authkey expiration" "$TS_AUTHKEY_EXPIRATION")"
  TS_TAG="$(ui_input "Authkey tag" "ACL tag. For tagged nodes, Headscale reads this from the key." "$TS_TAG")"

  if key="$(headscale_authkey)"; then
    merge_secret_json "$(jq -cn --arg v "$key" '{tailscale_authkey:$v}')"
    ui_msg "Authkey stored" "Stored generated authkey in Vault at:\n${VAULT_KV_PATH}\n\nKey name: tailscale_authkey"
  elif ui_yesno "Authkey generation failed" "Generation failed. Paste an existing authkey instead?" "yes"; then
    key="$(ui_secret "Tailscale authkey" "Paste authkey to store as tailscale_authkey.")"
    [ -n "$key" ] && merge_secret_json "$(jq -cn --arg v "$key" '{tailscale_authkey:$v}')"
  fi
}

configure_vault() {
  local seal_json sealed env_json suggested_role suggested_path suggested_policy
  need_cmd curl
  need_cmd jq

  valid_stack_name "$STACK_NAME" || { echo "Invalid STACK_NAME for Docker/container naming: $STACK_NAME" >&2; exit 2; }
  parse_kv_path

  ui_msg "Service Vault setup" "Service: ${STACK_NAME}\nRepo: ${REPO_ROOT}\nControls: ${CONTROLS_ENV}\nService env: ${SERVICE_ENV}\nVault API: ${VAULT_API_ADDR}\nVault Agent: ${VAULT_ADDR}\nKV path: ${VAULT_KV_PATH}\nAppRole: ${VAULT_APPROLE_NAME}"

  VAULT_API_ADDR="$(ui_input "Vault API address" "Main Vault address from this Docker host" "$VAULT_API_ADDR")"
  VAULT_API_CACERT="$(ui_input "Vault CA cert" "Host path to Vault CA cert, blank to use system trust" "$VAULT_API_CACERT")"
  if ui_yesno "TLS verification" "Skip Vault TLS certificate verification?" "no"; then VAULT_SKIP_VERIFY=true; else VAULT_SKIP_VERIFY=false; fi
  refresh_curl_opts

  seal_json="$(vault_api_noauth GET sys/seal-status)" || exit 1
  sealed="$(printf '%s' "$seal_json" | jq -r '.sealed // empty')"
  [ "$sealed" = "true" ] && { ui_msg "Vault sealed" "Vault at ${VAULT_API_ADDR} is sealed. Unseal it first."; exit 1; }

  prompt_parent_token

  STACK_NAME="$(ui_input "Service name" "Service/stack name" "$STACK_NAME")"
  valid_stack_name "$STACK_NAME" || { echo "Invalid STACK_NAME for Docker/container naming: $STACK_NAME" >&2; exit 2; }
  suggested_role="$STACK_NAME"
  suggested_path="kv/data/${STACK_NAME}"
  suggested_policy="app-${STACK_NAME}-read-kv"

  VAULT_APPROLE_NAME="$(ui_input "AppRole name" "Vault AppRole name" "${VAULT_APPROLE_NAME:-$suggested_role}")"
  [ "$VAULT_APPROLE_NAME" = "" ] && VAULT_APPROLE_NAME="$suggested_role"
  valid_vault_name "$VAULT_APPROLE_NAME" || { echo "Invalid VAULT_APPROLE_NAME: $VAULT_APPROLE_NAME" >&2; exit 2; }

  VAULT_KV_PATH="$(ui_input "Vault KV path" "KV v2 path used by Vault Agent" "${VAULT_KV_PATH:-$suggested_path}")"
  [ "$VAULT_KV_PATH" = "" ] && VAULT_KV_PATH="$suggested_path"
  parse_kv_path

  VAULT_POLICY_NAME="$(ui_input "Policy name" "Vault policy name" "${VAULT_POLICY_NAME:-$suggested_policy}")"
  [ "$VAULT_POLICY_NAME" = "" ] && VAULT_POLICY_NAME="$suggested_policy"
  valid_vault_name "$VAULT_POLICY_NAME" || { echo "Invalid VAULT_POLICY_NAME: $VAULT_POLICY_NAME" >&2; exit 2; }

  VAULT_APPROLE_SECRET_ID_USES="$(ui_input "Secret ID uses" "Use 0 for unlimited restarts, 1 for single-use." "$VAULT_APPROLE_SECRET_ID_USES")"

  ui_yesno "Confirm Vault changes" "Create/update policy '${VAULT_POLICY_NAME}' and AppRole '${VAULT_APPROLE_NAME}' for ${VAULT_KV_PATH}?" "yes" || { echo "Cancelled." >&2; exit 1; }
  write_policy_and_approle
  write_local_approle_files

  if [ "$SKIP_ENV_IMPORT" -eq 0 ] && { [ "$IMPORT_ENV" -eq 1 ] || ui_yesno "Import .env secrets" "Import non-platform values from ${SERVICE_ENV} into Vault?" "no"; }; then
    env_json="$(env_import_json "$SERVICE_ENV")"
    if [ "$env_json" != "{}" ]; then
      merge_secret_json "$env_json"
      ui_msg "KV updated" "Imported selected .env values into Vault at ${VAULT_KV_PATH}."
    else
      ui_msg "No values imported" "No importable .env values were found."
    fi
  fi

  maybe_generate_authkey

  ui_msg "Done" "Service setup complete.\n\nVault Agent auth files:\n${REPO_ROOT}/runtime/vault-auth/role_id\n${REPO_ROOT}/runtime/vault-auth/secret_id\n\nVault Agent will render from:\n${VAULT_KV_PATH}"
}

main() {
  case "$MODE" in
    bootstrap)
      bootstrap_runtime
      ui_msg "Runtime prepared" "Prepared runtime folders under:\n${REPO_ROOT}\n\nDeployment convention:\n/home/common/stacks/<service-name>/"
      ;;
    vault|all)
      bootstrap_runtime
      configure_vault
      ;;
    *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
  esac
}

main "$@"
