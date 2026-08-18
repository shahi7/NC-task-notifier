Warning: your password will expire in 0 days.
#!/usr/bin/env bash
# Prime01 Vault Operator
#
# One interactive operator tool for:
#   - short-lived in-memory Vault session tokens
#   - scoped child/operator token minting to tmpfs-backed files
#   - reusable platform factory/delegated token workflows
#   - Vault KV v1/v2 browsing and simple field editing
#   - AppRole role_id/secret_id rendering for Vault Agent
#
# Security posture:
#   - secret-bearing temp files are kept under a tmpfs/ramfs workspace
#   - human-supplied tokens are kept in memory only and cleared after use
#   - the operator session token is auto-revoked on exit
#   - token output files are written 0600 and never through symlinks
#   - Vault API calls use a temporary curl config in tmpfs so tokens are not
#     exposed as process arguments
#   - .env and compose files are treated as untrusted data, not sourced/evaled
#
# Automation / Codex-friendly flags:
#   -h, --help
#       Show the CLI help and exit.
#
#   --mode menu|configure|settings|session|kv|approle|tokens|docker
#       Start directly in a workflow. Default: menu.
#       Docker mode is the read-only Stack / Vault Agent Doctor. It checks Prime01 stack/Vault Agent integrity and can audit expected/template Vault keys against actual KV keys when a session token is active.
#       Most workflows are still interactive, but this skips the main menu.
#
#   --no-connect-prompt
#       Do not open the Vault connection TUI first. Use saved settings,
#       environment variables, and any CLI overrides instead.
#
#   --vault-addr URL
#   --vault-cacert PATH
#   --vault-namespace NAME
#   --no-vault-namespace
#   --vault-skip-verify true|false
#       Override Vault connection values for this run. These are applied
#       after config/settings.json is loaded.
#
#   --vault-token-file PATH
#       Read the parent/operator token from a root-only file instead of
#       prompting. Symlinks are refused. Use carefully for automation.
#
#   --session-ttl TTL
#       TTL for short-lived in-memory operator sessions. Examples: 15m, 2h.
#
#   --redaction full|partial|values
#       KV value display mode for this run. Default comes from settings.
#
#   --token-output-dir PATH
#       Directory for temporary token-drop outputs. Default: config/token-drop.
#
#   --tmp-parent PATH
#       Parent tmpfs/ramfs directory for secret-bearing temp files.
#
#   --trace | --no-trace
#       Enable or disable [TRACE] function-level logging.
#
# Environment-only path override, evaluated before settings load:
#   OPERATOR_CONFIG_DIR=/path/to/config

set -Eeuo pipefail
set +x
IFS=$'\n\t'
umask 077

# =============================================================================
# Paths and global state
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_BASENAME="$(basename -- "${BASH_SOURCE[0]}")"
OPERATOR_HOME="${OPERATOR_HOME:-$SCRIPT_DIR}"
CONFIG_DIR="${OPERATOR_CONFIG_DIR:-$OPERATOR_HOME/config}"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
STACKS_FILE="$CONFIG_DIR/stacks.json"
INTEGRITY_FILE="$CONFIG_DIR/integrity.json"

if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="${REPO_ROOT:-$(pwd)}"
fi

INITIAL_ENV_KEYS="$(env | sed 's/=.*//' | sort -u)"

: "${EDITOR:=nano}"
: "${TOKEN_RUNTIME_DIR:=$CONFIG_DIR/token-drop}"
: "${TOKEN_TMPFS_FALLBACK_DIR:=/dev/shm/vault-v2/operator-tokens}"
: "${UNSEAL_SCRIPT:=/home/common/vault-v2/scripts/legacy/03-unseal-interactive.sh}"
: "${STACK_NAME:=$(basename "$REPO_ROOT")}"
: "${KV_DEFAULT_MOUNT:=kv}"
: "${KV_DEFAULT_VERSION:=2}"
: "${OPERATOR_TRACE:=0}"
REDACTION_LEVEL="${REDACTION_LEVEL:-full}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-}"

RUN_MODE="menu"
NO_CONNECTION_PROMPT=0
CLI_VAULT_ADDR=""
CLI_VAULT_CACERT=""
CLI_VAULT_NAMESPACE="__unset__"
CLI_VAULT_NAMESPACE_ENABLED="__unset__"
CLI_VAULT_SKIP_VERIFY=""
CLI_VAULT_TOKEN_FILE=""
CLI_SESSION_TTL=""
CLI_REDACTION_LEVEL=""
CLI_TOKEN_OUTPUT_DIR=""
CLI_TMP_PARENT=""

TMP_PARENT="${TMP_PARENT:-/dev/shm/prime01-vault-operator}"
TMP_DIR=""
TOKEN_OUTPUT_DIR=""

CURRENT_TOKEN=""
SUPPLIED_TOKEN=""
SESSION_TOKEN=""
SESSION_TTL="${SESSION_TTL:-15m}"
SESSION_TOKEN_MINTED=0
SESSION_TOKEN_AUTO_REVOKE=1

VAULT_ADDR="${VAULT_ADDR:-${VAULT_API_ADDR:-${MAIN_VAULT_ADDR:-}}}"
VAULT_CACERT="${VAULT_CACERT:-${VAULT_API_CACERT:-${HOST_VAULT_CA_CERT:-}}}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_NAMESPACE_ENABLED="${VAULT_NAMESPACE_ENABLED:-auto}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

KNOWN_PROJECTS=(arcane authentik gitlab headscale headplane smtp-relay traefik vault vaultwarden)
DELEGATE_ROLE="operator-delegate"
FACTORY_POLICY="operator-platform-token-factory"
PLATFORM_POLICY="operator-platform"

MENU_TAGS=()
MENU_DESCS=()

# =============================================================================
# Basic helpers
# =============================================================================

cleanup() {
  local rc=$?
  if [[ -n "${SESSION_TOKEN:-}" && "$SESSION_TOKEN_AUTO_REVOKE" == "1" ]]; then
    revoke_session_token || true
  fi
  unset SUPPLIED_TOKEN CURRENT_TOKEN SESSION_TOKEN
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  return "$rc"
}
trap cleanup EXIT INT TERM

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
action_log() { echo "[ACTION] $*" >&2; }
trace_log() {
  # Opt-in function tracing. Enable with OPERATOR_TRACE=1.
  # Keep this explicit instead of using a DEBUG trap so secrets are not
  # accidentally logged from arbitrary commands.
  normalize_bool "${OPERATOR_TRACE:-0}" && echo "[TRACE] ${FUNCNAME[1]}${*:+: $*}" >&2 || true
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

env_was_set() { grep -qx -- "$1" <<< "$INITIAL_ENV_KEYS"; }

normalize_bool() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

vault_namespace_is_enabled() {
  case "${VAULT_NAMESPACE_ENABLED,,}" in
    1|true|yes|y|on) return 0 ;;
    0|false|no|n|off) return 1 ;;
    auto|"") [[ -n "${VAULT_NAMESPACE:-}" ]] ;;
    *) [[ -n "${VAULT_NAMESPACE:-}" ]] ;;
  esac
}

vault_namespace_display() {
  if vault_namespace_is_enabled && [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    printf '%s' "$VAULT_NAMESPACE"
  else
    printf 'disabled'
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

safe_name() {
  local s="$1"
  s="${s//[^A-Za-z0-9_.-]/-}"
  s="${s#-}"
  s="${s%-}"
  printf '%s' "${s:-operator}"
}

validate_project() {
  local project="$1"
  [[ "$project" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid project name: $project"
}

sanitize_abs_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" == /* ]] || return 1
  [[ "$p" != *$'\n'* && "$p" != *$'\0'* ]] || return 1
  (( ${#p} <= 4096 )) || return 1
  return 0
}

is_tmpfs_path() {
  local target="$1" fstype=""
  if have_cmd findmnt; then
    fstype="$(findmnt -n -o FSTYPE -T "$target" 2>/dev/null || true)"
    [[ "$fstype" == "tmpfs" || "$fstype" == "ramfs" ]]
    return
  fi
  case "$target" in
    /dev/shm|/dev/shm/*) return 0 ;;
    *) return 1 ;;
  esac
}

mk_tmp_file() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] || die "Temporary workspace is not initialized"
  mktemp "$TMP_DIR/tmp.XXXXXXXX"
}

# =============================================================================
# TUI helpers
# =============================================================================

has_whiptail() { have_cmd whiptail; }
has_dialog() { have_cmd dialog; }

ui_msg() {
  local title="$1" msg="$2"
  if has_whiptail; then
    whiptail --title "$title" --msgbox "$msg" 16 86
  elif has_dialog; then
    dialog --title "$title" --msgbox "$msg" 16 86
    clear || true
  else
    if [[ -t 0 || -t 1 || -t 2 ]]; then
      printf '\n%s\n%s\n\n' "$title" "$msg" > /dev/tty
    else
      printf '\n%s\n%s\n\n' "$title" "$msg" >&2
    fi
  fi
}

ui_textbox() {
  local title="$1" text="$2" file
  file="$(mk_tmp_file)"
  printf '%s
' "$text" > "$file"

  if has_whiptail; then
    whiptail --title "$title" --scrolltext --textbox "$file" 28 100
  elif has_dialog; then
    dialog --title "$title" --textbox "$file" 28 100
    clear || true
  else
    if [[ -t 0 || -t 1 || -t 2 ]]; then
      printf '
%s
%s

' "$title" "$(printf '%*s' "${#title}" '' | tr ' ' '=')" > /dev/tty
      if have_cmd less; then
        less -R "$file" < /dev/tty > /dev/tty
      else
        cat "$file" > /dev/tty
      fi
    else
      printf '
%s
%s

' "$title" "$(printf '%*s' "${#title}" '' | tr ' ' '=')" >&2
      cat "$file" >&2
    fi
  fi
}

ui_yesno() {
  local title="$1" msg="$2" default="${3:-yes}" answer prompt rc
  if has_whiptail; then
    if [[ "$default" == "no" ]]; then
      whiptail --title "$title" --defaultno --yesno "$msg" 16 86
    else
      whiptail --title "$title" --yesno "$msg" 16 86
    fi
    return $?
  elif has_dialog; then
    if [[ "$default" == "no" ]]; then
      dialog --title "$title" --defaultno --yesno "$msg" 16 86
    else
      dialog --title "$title" --yesno "$msg" 16 86
    fi
    rc=$?
    clear || true
    return "$rc"
  else
    [[ "$default" == "no" ]] && prompt="y/N" || prompt="Y/n"
    while true; do
      read -r -p "$msg [$prompt]: " answer < /dev/tty
      answer="${answer:-$default}"
      case "$answer" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
      esac
    done
  fi
}

ui_input() {
  local title="$1" msg="$2" default="${3:-}" value=""
  if has_whiptail; then
    value="$(whiptail --title "$title" --inputbox "$msg" 11 86 "$default" 3>&1 1>&2 2>&3)" || return 1
  elif has_dialog; then
    value="$(dialog --title "$title" --inputbox "$msg" 11 86 "$default" 3>&1 1>&2 2>&3)" || return 1
    clear || true
  else
    read -r -p "$msg [$default]: " value < /dev/tty
    value="${value:-$default}"
  fi
  printf '%s' "$value"
}

ui_secret() {
  local title="$1" msg="$2" value=""
  if has_whiptail; then
    value="$(whiptail --title "$title" --passwordbox "$msg" 11 86 3>&1 1>&2 2>&3)" || return 1
  elif has_dialog; then
    value="$(dialog --title "$title" --passwordbox "$msg" 11 86 3>&1 1>&2 2>&3)" || return 1
    clear || true
  else
    read -r -s -p "$msg: " value < /dev/tty
    printf '\n' > /dev/tty
  fi
  printf '%s' "$value"
}

menu_reset() { MENU_TAGS=(); MENU_DESCS=(); }

menu_add() {
  local tag="$1" desc="$2"
  MENU_TAGS+=("$tag")
  MENU_DESCS+=("$desc")
}

# whiptail/dialog do not support truly disabled menu rows. For capability-aware
# menus we keep locked choices visible, mark them clearly, and reject selection
# with an explanation. This preserves the power hierarchy without hiding useful
# operator context.
menu_add_power() {
  local tag="$1" desc="$2" enabled="${3:-true}" reason="${4:-missing required capability}"
  if [[ "$enabled" == "true" ]]; then
    menu_add "$tag" "$desc"
  else
    menu_add "locked:${tag}" "[locked] ${desc} (${reason})"
  fi
}

menu_is_locked_choice() {
  [[ "$1" == locked:* ]]
}

locked_choice_msg() {
  local choice="$1"
  choice="${choice#locked:}"
  ui_msg "Locked token workflow" "This option is shown for context but is not available with the currently loaded token.

Workflow: ${choice}

Use a stronger token, start a root-derived short-lived break-glass session, or choose a workflow that prompts for a separate privileged token."
}

menu_choose() {
  local title="$1" prompt="$2"
  local -a items=()
  local i choice n answer tag desc

  for i in "${!MENU_TAGS[@]}"; do
    items+=("${MENU_TAGS[$i]}" "${MENU_DESCS[$i]}")
  done

  if has_whiptail; then
    choice="$(whiptail --title "$title" --menu "$prompt" 24 92 15 "${items[@]}" 3>&1 1>&2 2>&3)" || return 1
  elif has_dialog; then
    choice="$(dialog --title "$title" --menu "$prompt" 24 92 15 "${items[@]}" 3>&1 1>&2 2>&3)" || return 1
    clear || true
  else
    printf '\n%s\n%s\n\n' "$title" "$prompt" > /dev/tty
    n=1
    for i in "${!MENU_TAGS[@]}"; do
      printf '  %2d) %-28s %s\n' "$n" "${MENU_TAGS[$i]}" "${MENU_DESCS[$i]}" > /dev/tty
      n=$((n + 1))
    done
    while true; do
      read -r -p "Choose an option: " answer < /dev/tty
      if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#MENU_TAGS[@]} )); then
        choice="${MENU_TAGS[$((answer - 1))]}"
        break
      fi
      for tag in "${MENU_TAGS[@]}"; do
        if [[ "$answer" == "$tag" ]]; then
          choice="$answer"
          break 2
        fi
      done
      echo "Invalid choice." > /dev/tty
    done
  fi

  printf '%s' "$choice"
}

# =============================================================================
# JSON, settings, and workspace
# =============================================================================

json_write_atomic() {
  local file="$1" tmp input
  input="$(cat)"
  printf '%s' "$input" | jq '.' >/dev/null 2>&1 || die "Invalid JSON for $file"
  mkdir -p -- "$(dirname -- "$file")"
  tmp="${file}.tmp.$$"
  printf '%s\n' "$input" > "$tmp"
  chmod 0600 "$tmp"
  mv -- "$tmp" "$file"
}

write_default_stacks_json() {
  jq -n \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      version: 1,
      created_at: $created_at,
      notes: "Prime01 Vault Operator stack registry. Stack entries are discovered or added by the operator and must be treated as untrusted input.",
      default_search_roots: ["/home/common"],
      schema: {
        id: "short stack id, for example arcane or headscale",
        root: "absolute stack root, usually /home/common/<service>",
        compose_files: ["absolute docker compose file paths"],
        env_file: "absolute .env path when present",
        vault_agent_container_hint: "optional container name hint",
        app_container_hint: "optional container name hint",
        ts_sidecar_container_hint: "optional container name hint"
      },
      stacks: []
    }'
}

ensure_stacks_metadata() {
  local current updated
  current="$(jq '.' "$STACKS_FILE")" || die "Failed to parse $STACKS_FILE"
  updated="$(jq \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.version = (.version // 1)
     | .notes = (.notes // "Prime01 Vault Operator stack registry. Stack entries are discovered or added by the operator and must be treated as untrusted input.")
     | .default_search_roots = (.default_search_roots // ["/home/common"])
     | .schema = (.schema // {
        id: "short stack id, for example arcane or headscale",
        root: "absolute stack root, usually /home/common/<service>",
        compose_files: ["absolute docker compose file paths"],
        env_file: "absolute .env path when present",
        vault_agent_container_hint: "optional container name hint",
        app_container_hint: "optional container name hint",
        ts_sidecar_container_hint: "optional container name hint"
      })
     | .stacks = (.stacks // [])
     | .metadata_refreshed_at = $updated_at' <<< "$current")"
  printf '%s\n' "$updated" | json_write_atomic "$STACKS_FILE"
}

file_sha256_or_missing() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

refresh_integrity_manifest() {
  local now script_hash settings_hash stacks_hash script_path
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  script_path="$SCRIPT_DIR/$SCRIPT_BASENAME"
  script_hash="$(file_sha256_or_missing "$script_path")"
  settings_hash="$(file_sha256_or_missing "$SETTINGS_FILE")"
  stacks_hash="$(file_sha256_or_missing "$STACKS_FILE")"

  jq -n \
    --arg now "$now" \
    --arg script_path "$script_path" \
    --arg script_hash "$script_hash" \
    --arg settings_path "$SETTINGS_FILE" \
    --arg settings_hash "$settings_hash" \
    --arg stacks_path "$STACKS_FILE" \
    --arg stacks_hash "$stacks_hash" \
    '{
      version: 1,
      updated_at: $now,
      notes: "Tamper-evidence manifest for operator-managed files. Refresh from Operator settings after an intentional script/settings/registry change.",
      files: [
        {path: $script_path, sha256: $script_hash, purpose: "operator script"},
        {path: $settings_path, sha256: $settings_hash, purpose: "non-secret operator settings"},
        {path: $stacks_path, sha256: $stacks_hash, purpose: "stack registry"}
      ]
    }' | json_write_atomic "$INTEGRITY_FILE"
}

ensure_config() {
  mkdir -p -- "$CONFIG_DIR"
  chmod 0700 "$CONFIG_DIR"

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    jq -n \
      --arg tmpfs "$TMP_PARENT" \
      --arg ttl "$SESSION_TTL" \
      --arg addr "${VAULT_ADDR:-https://127.0.0.1:8200}" \
      --arg cacert "${VAULT_CACERT:-}" \
      --arg namespace "${VAULT_NAMESPACE:-}" \
      --arg skip "$VAULT_SKIP_VERIFY" \
      --arg token_out "$TOKEN_RUNTIME_DIR" \
      '{
        version: 1,
        tmpfs_dir: $tmpfs,
        session_ttl: $ttl,
        vault_addr: $addr,
        vault_cacert: $cacert,
        vault_namespace: $namespace,
        vault_namespace_enabled: ($namespace | length > 0),
        vault_skip_verify: $skip,
        token_output_dir: $token_out,
        redaction_level: "full",
        editor_mode: "field-only"
      }' \
      | json_write_atomic "$SETTINGS_FILE"
  fi

  if [[ ! -f "$STACKS_FILE" ]]; then
    write_default_stacks_json | json_write_atomic "$STACKS_FILE"
  else
    ensure_stacks_metadata
  fi

  if [[ ! -f "$INTEGRITY_FILE" ]]; then
    refresh_integrity_manifest
  elif [[ "$(jq -r '(.files // []) | length' "$INTEGRITY_FILE" 2>/dev/null || echo 0)" == "0" ]]; then
    refresh_integrity_manifest
  fi
}

load_settings() {
  local saved
  saved="$(jq '.' "$SETTINGS_FILE")" || die "Failed to parse $SETTINGS_FILE"

  TMP_PARENT="$(jq -r --arg d "$TMP_PARENT" '.tmpfs_dir // $d' <<< "$saved")"
  SESSION_TTL="$(jq -r --arg d "$SESSION_TTL" '.session_ttl // $d' <<< "$saved")"

  if ! env_was_set VAULT_ADDR && ! env_was_set VAULT_API_ADDR && ! env_was_set MAIN_VAULT_ADDR; then
    VAULT_ADDR="$(jq -r --arg d "${VAULT_ADDR:-https://127.0.0.1:8200}" '.vault_addr // $d' <<< "$saved")"
  fi

  if ! env_was_set VAULT_CACERT && ! env_was_set VAULT_API_CACERT && ! env_was_set HOST_VAULT_CA_CERT; then
    VAULT_CACERT="$(jq -r --arg d "${VAULT_CACERT:-}" '.vault_cacert // $d' <<< "$saved")"
  fi

  if ! env_was_set VAULT_NAMESPACE; then
    VAULT_NAMESPACE="$(jq -r --arg d "${VAULT_NAMESPACE:-}" '.vault_namespace // $d' <<< "$saved")"
  fi

  if ! env_was_set VAULT_NAMESPACE_ENABLED; then
    VAULT_NAMESPACE_ENABLED="$(jq -r '.vault_namespace_enabled // (if ((.vault_namespace // "") == "") then false else true end)' <<< "$saved")"
  fi

  if ! env_was_set VAULT_SKIP_VERIFY; then
    VAULT_SKIP_VERIFY="$(jq -r --arg d "$VAULT_SKIP_VERIFY" '.vault_skip_verify // $d' <<< "$saved")"
  fi

  if ! env_was_set TOKEN_RUNTIME_DIR; then
    TOKEN_RUNTIME_DIR="$(jq -r --arg d "$TOKEN_RUNTIME_DIR" '.token_output_dir // $d' <<< "$saved")"
  fi

  if ! env_was_set REDACTION_LEVEL; then
    REDACTION_LEVEL="$(jq -r --arg d "$REDACTION_LEVEL" '.redaction_level // $d' <<< "$saved")"
  fi

  case "$REDACTION_LEVEL" in
    full|partial|values) ;;
    none|show|unredacted) REDACTION_LEVEL="values" ;;
    *)
      warn "Unknown redaction_level in settings: $REDACTION_LEVEL. Falling back to full."
      REDACTION_LEVEL="full"
      ;;
  esac
}

save_settings() {
  local updated current ns_enabled_json
  current="$(jq '.' "$SETTINGS_FILE")"
  if vault_namespace_is_enabled; then ns_enabled_json=true; else ns_enabled_json=false; fi
  updated="$(jq \
    --arg tmpfs "$TMP_PARENT" \
    --arg ttl "$SESSION_TTL" \
    --arg addr "$VAULT_ADDR" \
    --arg cacert "$VAULT_CACERT" \
    --arg namespace "$VAULT_NAMESPACE" \
    --argjson namespace_enabled "$ns_enabled_json" \
    --arg skip "$VAULT_SKIP_VERIFY" \
    --arg token_out "$TOKEN_RUNTIME_DIR" \
    --arg redaction "$REDACTION_LEVEL" \
    '.tmpfs_dir=$tmpfs | .session_ttl=$ttl | .vault_addr=$addr | .vault_cacert=$cacert | .vault_namespace=$namespace | .vault_namespace_enabled=$namespace_enabled | .vault_skip_verify=$skip | .token_output_dir=$token_out | .redaction_level=$redaction' \
    <<< "$current")"
  printf '%s\n' "$updated" | json_write_atomic "$SETTINGS_FILE"
}

save_namespace_setting() {
  local current updated ns_enabled_json
  current="$(jq '.' "$SETTINGS_FILE")"
  if vault_namespace_is_enabled; then ns_enabled_json=true; else ns_enabled_json=false; fi
  updated="$(jq \
    --arg namespace "$VAULT_NAMESPACE" \
    --argjson namespace_enabled "$ns_enabled_json" \
    '.vault_namespace=$namespace | .vault_namespace_enabled=$namespace_enabled' \
    <<< "$current")"
  printf '%s\n' "$updated" | json_write_atomic "$SETTINGS_FILE"
}

init_tmp_dir() {
  [[ -n "$TMP_PARENT" ]] || die "TMP_PARENT is unset"
  mkdir -p -- "$TMP_PARENT"
  chmod 0700 "$TMP_PARENT" 2>/dev/null || true

  if ! is_tmpfs_path "$TMP_PARENT"; then
    die "Temporary workspace $TMP_PARENT is not tmpfs/ramfs. Refusing to create secrets in persistent storage."
  fi

  TMP_DIR="$(mktemp -d "$TMP_PARENT/prime01.XXXXXXXX")"
  chmod 0700 "$TMP_DIR"
  log "Using temporary workspace $TMP_DIR"
}

resolve_token_output_dir() {
  trace_log "start"
  # Tokens that are meant to be retrieved by the operator are written to a
  # short-term drop directory. By default this is beside the operator config:
  #   <script-dir>/config/token-drop
  # This is intentionally convenient for copy-out workflows. If the directory
  # is not memory-backed, the script warns clearly and the cleanup helper can
  # remove the file after it has been moved.
  mkdir -p -- "$TOKEN_RUNTIME_DIR" 2>/dev/null || true

  if [[ -d "$TOKEN_RUNTIME_DIR" ]]; then
    TOKEN_OUTPUT_DIR="$TOKEN_RUNTIME_DIR"
  else
    mkdir -p -- "$TOKEN_TMPFS_FALLBACK_DIR"
    [[ -d "$TOKEN_TMPFS_FALLBACK_DIR" ]] || die "Unable to create fallback token output directory: $TOKEN_TMPFS_FALLBACK_DIR"
    TOKEN_OUTPUT_DIR="$TOKEN_TMPFS_FALLBACK_DIR"
    warn "Preferred token output path could not be created: $TOKEN_RUNTIME_DIR"
    warn "Using fallback token output path: $TOKEN_OUTPUT_DIR"
  fi

  chmod 0700 "$TOKEN_OUTPUT_DIR" 2>/dev/null || true

  if ! is_tmpfs_path "$TOKEN_OUTPUT_DIR"; then
    warn "Token output directory is not tmpfs/ramfs: $TOKEN_OUTPUT_DIR"
    warn "Treat files in this folder as temporary secrets and delete them after retrieval."
  fi
}

# =============================================================================
# Vault API and connection
# =============================================================================

curl_common_opts() {
  local -a opts=(-sS --connect-timeout 5 --max-time 60)
  if normalize_bool "$VAULT_SKIP_VERIFY"; then
    opts+=(-k)
  fi
  if [[ -n "$VAULT_CACERT" ]]; then
    opts+=(--cacert "$VAULT_CACERT")
  fi
  printf '%s\0' "${opts[@]}"
}

vault_api() {
  local method="$1" path="$2" body_file="${3:-}"
  local url response http body cfg err_file
  local -a opts=()

  [[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is not set"
  cfg="$(mk_tmp_file)"
  err_file="$(mk_tmp_file)"
  url="${VAULT_ADDR%/}/v1/${path#/}"

  {
    printf 'header = "X-Vault-Request: true"\n'
    printf 'header = "Content-Type: application/json"\n'
    [[ -n "$CURRENT_TOKEN" ]] && printf 'header = "X-Vault-Token: %s"\n' "$CURRENT_TOKEN"
    vault_namespace_is_enabled && [[ -n "$VAULT_NAMESPACE" ]] && printf 'header = "X-Vault-Namespace: %s"\n' "$VAULT_NAMESPACE"
  } > "$cfg"

  while IFS= read -r -d '' opt; do opts+=("$opt"); done < <(curl_common_opts)

  if [[ -n "$body_file" ]]; then
    response="$(curl "${opts[@]}" -w $'\n%{http_code}' -K "$cfg" -X "$method" --data-binary "@$body_file" "$url" 2>"$err_file")" || {
      echo "Vault API request failed: $method /v1/${path#/}" >&2
      [[ -s "$err_file" ]] && printf 'curl: %s\n' "$(tr '\n' ' ' < "$err_file")" >&2
      return 1
    }
  else
    response="$(curl "${opts[@]}" -w $'\n%{http_code}' -K "$cfg" -X "$method" "$url" 2>"$err_file")" || {
      echo "Vault API request failed: $method /v1/${path#/}" >&2
      [[ -s "$err_file" ]] && printf 'curl: %s\n' "$(tr '\n' ' ' < "$err_file")" >&2
      return 1
    }
  fi

  http="${response##*$'\n'}"
  body="${response%$'\n'"$http"}"

  if [[ ! "$http" =~ ^2[0-9][0-9]$ ]]; then
    echo "Vault API returned HTTP $http for $method /v1/${path#/}" >&2
    [[ -n "$body" ]] && printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s' "$body"
}

vault_api_noauth() {
  local old="$CURRENT_TOKEN" rc
  CURRENT_TOKEN=""
  vault_api "$@"
  rc=$?
  CURRENT_TOKEN="$old"
  return "$rc"
}

vault_lookup_self() {
  vault_api GET auth/token/lookup-self
}

configure_vault_connection() {
  trace_log "start"
  action_log "Configure Vault connection"
  local addr cacert namespace skip_default seal_json sealed

  addr="$(ui_input "Vault address" "Vault API address" "${VAULT_ADDR:-https://127.0.0.1:8200}")" || return 1
  [[ -n "$addr" ]] || die "Vault address is required"
  VAULT_ADDR="$addr"

  cacert="$(ui_input "Vault CA cert" "Host path to Vault CA cert. Leave blank if not needed." "${VAULT_CACERT:-}")" || return 1
  VAULT_CACERT="$cacert"

  if ui_yesno "Vault namespace" "Does this Vault use Vault Enterprise namespaces?

Choose No for normal/community Vault. This will be remembered and no namespace header will be sent." "$(vault_namespace_is_enabled && echo yes || echo no)"; then
    namespace="$(ui_input "Vault namespace" "Vault namespace. Leave blank to disable namespace support." "${VAULT_NAMESPACE:-}")" || return 1
    VAULT_NAMESPACE="$namespace"
    if [[ -n "$VAULT_NAMESPACE" ]]; then
      VAULT_NAMESPACE_ENABLED="true"
    else
      VAULT_NAMESPACE_ENABLED="false"
    fi
  else
    VAULT_NAMESPACE=""
    VAULT_NAMESPACE_ENABLED="false"
  fi

  skip_default="no"
  normalize_bool "$VAULT_SKIP_VERIFY" && skip_default="yes"
  if ui_yesno "TLS verification" "Skip Vault TLS certificate verification?\n\nCurrent value: ${VAULT_SKIP_VERIFY}" "$skip_default"; then
    VAULT_SKIP_VERIFY="true"
  else
    VAULT_SKIP_VERIFY="false"
  fi

  save_settings

  if seal_json="$(vault_api_noauth GET sys/seal-status 2>/dev/null)"; then
    sealed="$(jq -r '.sealed // empty' <<< "$seal_json")"
    if [[ "$sealed" == "true" ]]; then
      ui_msg "Vault sealed" "Vault is reachable but sealed. Unseal before starting a session."
    fi
  else
    warn "Could not query Vault seal status at $VAULT_ADDR"
  fi
}

# =============================================================================
# Session and capability helpers
# =============================================================================

prompt_parent_token() {
  local purpose="${1:-Enter Vault operator token}"
  [[ -n "$SUPPLIED_TOKEN" ]] && return 0

  if [[ -n "${VAULT_TOKEN_FILE:-}" ]]; then
    action_log "Read Vault token from configured token file"
    SUPPLIED_TOKEN="$(read_token_file_secret "$VAULT_TOKEN_FILE")"
  else
    SUPPLIED_TOKEN="$(ui_secret "Vault token" "$purpose")" || die "Token prompt cancelled"
  fi

  SUPPLIED_TOKEN="${SUPPLIED_TOKEN//$'\r'/}"
  SUPPLIED_TOKEN="${SUPPLIED_TOKEN//$'\n'/}"
  [[ -n "$SUPPLIED_TOKEN" ]] || die "A token is required"
  [[ ! "$SUPPLIED_TOKEN" =~ [^[:print:]] ]] || die "Vault token contains non-printable characters"
}

validate_current_token() {
  vault_lookup_self >/dev/null || die "Vault token lookup failed. Token is invalid, expired, revoked, or for another Vault."
}

token_has_root_policy() {
  local lookup="$1"
  jq -e '(.data.policies // []) | index("root")' <<< "$lookup" >/dev/null 2>&1
}


# Return 0 when the currently selected Vault token carries the root policy.
# This is used only to make the root-derived token workflow explicit and safer.
current_token_is_root() {
  local lookup
  lookup="$(vault_lookup_self)" || return 1
  token_has_root_policy "$lookup"
}

mint_session_token() {
  local payload resp token lookup parent_policies_json parent_policy_list policy_name policy_file timestamp

  trace_log "start"
  action_log "Start secure session"

  prompt_parent_token "Paste the Vault token to use long enough to mint or start an operator session. Root tokens are never kept as the active token."
  CURRENT_TOKEN="$SUPPLIED_TOKEN"
  lookup="$(vault_lookup_self)" || die "Parent token lookup failed"

  if token_has_root_policy "$lookup"; then
    ui_msg "Root token detected" \
"This token has the root policy. The operator will NOT keep the real root token as the active session.

Recommended behavior:
- create a temporary broad operator policy
- mint a short-lived child token with that policy
- clear the supplied root token from memory
- auto-revoke the child session on exit"

    if ! ui_yesno "Mint root-derived operator child" \
"Mint a short-lived broad operator child session now?

TTL: $SESSION_TTL
This is powerful, but it is not the real root token." "yes"; then
      CURRENT_TOKEN=""
      SUPPLIED_TOKEN=""
      die "Session cancelled before using root token"
    fi

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    policy_name="operator-session-break-glass-${timestamp}"
    policy_file="$(mk_tmp_file)"

    self_policy > "$policy_file"
    printf '\n' >> "$policy_file"
    break_glass_policy >> "$policy_file"

    action_log "Install temporary session policy: $policy_name"
    write_acl_policy "$policy_name" "$policy_file"

    payload="$(mk_tmp_file)"
    jq -n \
      --arg policy "$policy_name" \
      --arg ttl "$SESSION_TTL" \
      '{policies:[$policy], ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:"prime01-root-derived-operator-session"}' \
      > "$payload"

    resp="$(vault_api POST auth/token/create "$payload")" || die "Failed to mint root-derived operator session token"
    token="$(jq -er '.auth.client_token' <<< "$resp")" || die "Could not parse session token"

    SESSION_TOKEN="$token"
    CURRENT_TOKEN="$SESSION_TOKEN"
    SESSION_TOKEN_MINTED=1
    SESSION_TOKEN_AUTO_REVOKE=1
    SUPPLIED_TOKEN=""
    unset token

    ui_msg "Session started" \
"Root-derived broad operator session minted.

Policy: $policy_name
TTL: $SESSION_TTL

The real root token was cleared from memory. This child session will be revoked on exit."
    return 0
  fi

  parent_policies_json="$(jq -c '(.data.policies // []) | map(select(. != "default" and . != "root"))' <<< "$lookup")"
  parent_policy_list="$(jq -r 'join(",")' <<< "$parent_policies_json")"

  if [[ -z "$parent_policy_list" ]]; then
    warn "Current token has no non-default policies to copy into a child session."
    if ui_yesno "Use supplied token directly?" "This token has no copyable non-default policies. Minting a child would likely create an unusable default-only token.

Use the supplied token directly for this operator run?

It will stay in memory only and will NOT be auto-revoked by this script." "yes"; then
      CURRENT_TOKEN="$SUPPLIED_TOKEN"
      SESSION_TOKEN=""
      SESSION_TOKEN_MINTED=0
      SESSION_TOKEN_AUTO_REVOKE=0
      SUPPLIED_TOKEN=""
      ui_msg "Session started" "Using supplied token directly for this run. It will not be written to disk or auto-revoked."
      return 0
    fi
    CURRENT_TOKEN=""
    SUPPLIED_TOKEN=""
    die "Could not start an operator session without usable policies"
  fi

  payload="$(mk_tmp_file)"
  jq -n \
    --argjson policies "$parent_policies_json" \
    --arg ttl "$SESSION_TTL" \
    '{policies:$policies, ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:"prime01-operator-session"}' \
    > "$payload"

  action_log "Mint short-lived child session from supplied token"
  set +e
  resp="$(vault_api POST auth/token/create "$payload")"
  local create_rc=$?
  set -e

  if [[ $create_rc -ne 0 || -z "$resp" ]]; then
    warn "Could not mint a child session from this token."
    if ui_yesno "Use supplied token directly?" \
"The supplied token could not mint a child session. This usually means it lacks auth/token/create or token role permissions.

Use the supplied token directly for this operator run instead?

It will stay in memory only and will NOT be auto-revoked by this script." "yes"; then
      CURRENT_TOKEN="$SUPPLIED_TOKEN"
      SESSION_TOKEN=""
      SESSION_TOKEN_MINTED=0
      SESSION_TOKEN_AUTO_REVOKE=0
      SUPPLIED_TOKEN=""
      ui_msg "Session started" "Using supplied token directly for this run. It will not be written to disk or auto-revoked."
      return 0
    fi
    CURRENT_TOKEN=""
    SUPPLIED_TOKEN=""
    die "Could not start an operator session"
  fi

  token="$(jq -er '.auth.client_token' <<< "$resp")" || die "Could not parse session token"
  SESSION_TOKEN="$token"
  CURRENT_TOKEN="$SESSION_TOKEN"
  SESSION_TOKEN_MINTED=1
  SESSION_TOKEN_AUTO_REVOKE=1
  SUPPLIED_TOKEN=""
  unset token

  ui_msg "Session started" \
"Short-lived operator session minted.

TTL: $SESSION_TTL
Policies copied from parent: ${parent_policy_list:-none}
Parent token was cleared from memory.
Session token will be revoked on exit."
}

ensure_session() {
  if [[ -n "$CURRENT_TOKEN" ]]; then
    return 0
  fi
  if ui_yesno "No session" "No active operator session exists. Start one now?" "yes"; then
    mint_session_token
  else
    return 1
  fi
}

revoke_session_token() {
  [[ -n "$SESSION_TOKEN" ]] || return 0
  local old="$CURRENT_TOKEN" rc
  CURRENT_TOKEN="$SESSION_TOKEN"
  set +e
  vault_api POST auth/token/revoke-self >/dev/null
  rc=$?
  set -e
  CURRENT_TOKEN="$old"
  if [[ $rc -eq 0 ]]; then
    log "Session token revoked"
  else
    warn "Failed to revoke session token"
  fi
  SESSION_TOKEN=""
  [[ "$CURRENT_TOKEN" == "$old" ]] || CURRENT_TOKEN=""
}

check_capability() {
  local path="$1" required="$2" payload resp cap
  payload="$(mk_tmp_file)"
  jq -n --arg path "$path" '{path:$path}' > "$payload"
  resp="$(vault_api POST sys/capabilities-self "$payload" 2>/dev/null || true)"
  [[ -n "$resp" ]] || return 1
  while IFS= read -r cap; do
    [[ "$cap" == "$required" || "$cap" == "sudo" || "$cap" == "root" ]] && return 0
  done < <(jq -r '.capabilities[]? // empty' <<< "$resp")
  return 1
}

require_capabilities() {
  local path="$1" cap missing=()
  shift
  for cap in "$@"; do
    check_capability "$path" "$cap" || missing+=("$cap")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  ui_yesno "Missing capabilities" "Missing capabilities on:\n$path\n\n${missing[*]}\n\nProceed anyway?" "no"
}

# Return success if the active token has any one of the listed capabilities
# on a path. Vault root/sudo responses are treated as satisfying all checks.
check_any_capability() {
  local path="$1" payload resp wanted cap
  shift

  payload="$(mk_tmp_file)"
  jq -n --arg path "$path" '{path:$path}' > "$payload"
  resp="$(vault_api POST sys/capabilities-self "$payload" 2>/dev/null || true)"
  [[ -n "$resp" ]] || return 1

  while IFS= read -r cap; do
    [[ "$cap" == "root" || "$cap" == "sudo" ]] && return 0
    for wanted in "$@"; do
      [[ "$cap" == "$wanted" ]] && return 0
    done
  done < <(jq -r '.capabilities[]? // empty' <<< "$resp" 2>/dev/null)

  return 1
}

# Preflight the specific powers needed to install/update an operator policy,
# create/update a token role, then mint through that token role. This avoids a
# confusing cascade of 403 errors followed by jq parse errors.
preflight_token_role_mint_permissions() {
  local policy_name="$1" role_name="$2" missing=""

  check_any_capability "sys/policies/acl/${policy_name}" create update ||     missing+="\n- sys/policies/acl/${policy_name}: create or update"

  check_any_capability "auth/token/roles/${role_name}" create update ||     missing+="\n- auth/token/roles/${role_name}: create or update"

  check_any_capability "auth/token/create/${role_name}" update ||     missing+="\n- auth/token/create/${role_name}: update"

  [[ -z "$missing" ]] && return 0

  ui_msg "Token lacks minting permissions" "The supplied token cannot complete this renewable break-glass workflow.\n\nMissing capabilities:${missing}\n\nUse the real root token for this bootstrap, or first update the token's policy to include token-role management for operator-* roles. Existing older break-glass tokens may be broad for KV/AppRole work but still unable to create token roles."
  return 1
}

# Capability predicates for the token-helper UI. These are intentionally coarse:
# they answer, "can the currently loaded token definitely perform this class of
# workflow?" If there is no active token, the UI treats privileged workflows as
# available because they will prompt for a token and preflight after the prompt.
token_context_loaded() {
  [[ -n "${CURRENT_TOKEN:-}" ]]
}

token_can_create_child() {
  check_any_capability "auth/token/create" update || check_any_capability "auth/token/create-orphan" update
}

token_can_write_operator_policy() {
  check_any_capability "sys/policies/acl/operator-preflight-probe" create update
}

token_can_manage_operator_role() {
  check_any_capability "auth/token/roles/operator-preflight-probe" create update
}

token_can_mint_operator_role() {
  check_any_capability "auth/token/create/operator-preflight-probe" update
}

token_can_mint_delegate_role() {
  check_any_capability "auth/token/create/${DELEGATE_ROLE}" update
}

token_can_renew_self() {
  check_any_capability "auth/token/renew-self" update
}

token_can_short_break_glass() {
  token_can_write_operator_policy && token_can_manage_operator_role && token_can_mint_operator_role
}

token_can_direct_scoped() {
  token_can_write_operator_policy && token_can_manage_operator_role && token_can_mint_operator_role
}

token_can_renewable_break_glass() {
  token_can_write_operator_policy && token_can_manage_operator_role && token_can_mint_operator_role
}

token_can_bootstrap_factory() {
  token_can_write_operator_policy && token_can_manage_operator_role && token_can_mint_operator_role
}

token_helper_enabled_bool() {
  local predicate="$1"
  if ! token_context_loaded; then
    printf 'true'
    return 0
  fi
  if "$predicate" >/dev/null 2>&1; then
    printf 'true'
  else
    printf 'false'
  fi
}

token_helper_prompt_summary() {
  if ! token_context_loaded; then
    cat <<'EOF'
Choose a token workflow.

No operator token is currently loaded, so privileged workflows will prompt for the token they need and run a preflight check after that prompt.
EOF
    return 0
  fi

  cat <<EOF
Choose a token workflow.

A token is currently loaded, so options that this token definitely cannot perform are shown as [locked]. Locked rows are visible so the power hierarchy stays clear.

High-power minting workflows will still ask whether to use this active token or prompt for a separate authority token. Prompting is the safer default.
EOF
}

run_workflow_with_current_or_prompt() {
  local purpose="$1" fn="$2" use_current="no"
  shift 2

  if [[ -n "${CURRENT_TOKEN:-}" ]]; then
    if ui_yesno "Token authority" "A token is already active for this operator session.

For token-minting workflows, the safer default is to prompt for the authority token for this workflow instead of silently using the active session token. This avoids creating a child from a weaker temporary session.

Use the active session token for this workflow?" "no"; then
      use_current="yes"
    fi
  fi

  if [[ "$use_current" == "yes" ]]; then
    "$fn" "$@"
  else
    run_with_prompted_token "$purpose" "$fn" "$@"
  fi
}

# =============================================================================
# Token policy templates and token minting
# =============================================================================

normalize_ttl() {
  local ttl="$1"
  ttl="${ttl// /}"
  if [[ "$ttl" =~ ^[0-9]+$ ]]; then printf '%sh' "$ttl"; return 0; fi
  if [[ "$ttl" =~ ^([0-9]+)d$ ]]; then printf '%sh' "$((BASH_REMATCH[1] * 24))"; return 0; fi
  if [[ "$ttl" =~ ^[0-9]+[smh]$ ]]; then printf '%s' "$ttl"; return 0; fi
  die "Invalid TTL: $ttl. Use values like 10m, 2h, 24h, 7d, or 30d."
}

choose_duration() {
  local title="$1" default="$2" choice custom
  menu_reset
  menu_add "$default" "Use suggested default"
  menu_add "10m" "10 minutes"
  menu_add "30m" "30 minutes"
  menu_add "2h" "2 hours"
  menu_add "4h" "4 hours"
  menu_add "12h" "12 hours"
  menu_add "24h" "24 hours"
  menu_add "7d" "7 days, converted to hours"
  menu_add "30d" "30 days, converted to hours"
  menu_add "custom" "Enter custom duration"
  choice="$(menu_choose "$title" "Choose a duration")" || return 1
  if [[ "$choice" == "custom" ]]; then
    custom="$(ui_input "$title" "Custom duration. Examples: 45m, 8h, 7d, 720h" "$default")"
    normalize_ttl "$custom"
  else
    normalize_ttl "$choice"
  fi
}

select_project() {
  local allow_custom="${1:-true}" choice default_project
  default_project="$(safe_name "${STACK_NAME:-authentik}")"
  menu_reset
  local p
  for p in "${KNOWN_PROJECTS[@]}"; do
    menu_add "$p" "Known project"
  done
  [[ "$allow_custom" == "true" ]] && menu_add "custom" "Enter another project name"
  choice="$(menu_choose "Project" "Choose a project")" || return 1
  if [[ "$choice" == "custom" ]]; then
    choice="$(ui_input "Project" "Project name" "$default_project")" || return 1
  fi
  validate_project "$choice"
  printf '%s' "$choice"
}

self_policy() {
  cat <<'EOF'
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}

path "sys/capabilities-self" {
  capabilities = ["update"]
}
EOF
}

kv_read_policy() {
  local project="$1"
  cat <<EOF
path "kv/data/${project}" {
  capabilities = ["read"]
}

path "kv/metadata/${project}" {
  capabilities = ["read", "list"]
}
EOF
}

kv_write_policy() {
  local project="$1"
  cat <<EOF
path "kv/data/${project}" {
  capabilities = ["create", "update", "patch", "read"]
}

path "kv/metadata/${project}" {
  capabilities = ["read", "list"]
}
EOF
}

approle_policy() {
  local project="$1"
  cat <<EOF
path "auth/approle/role/${project}/role-id" {
  capabilities = ["read"]
}

path "auth/approle/role/${project}/secret-id" {
  capabilities = ["update"]
}
EOF
}


system_discovery_policy() {
  cat <<'EOF'
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/*/tune" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}
EOF
}

platform_policy_body() {
  local p
  system_discovery_policy
  printf '\n'
  for p in "${KNOWN_PROJECTS[@]}"; do
    kv_write_policy "$p"
    printf '\n'
  done
  for p in arcane authentik gitlab headplane smtp-relay vault vaultwarden; do
    approle_policy "$p"
    printf '\n'
  done
}

token_factory_body() {
  cat <<EOF
path "auth/token/create/${DELEGATE_ROLE}" {
  capabilities = ["update"]
}
EOF
}

break_glass_policy() {
  cat <<'EOF'
path "kv/data/*" {
  capabilities = ["create", "update", "patch", "read", "delete"]
}

path "kv/metadata/*" {
  capabilities = ["create", "update", "patch", "read", "list", "delete"]
}

path "auth/approle/role/*/role-id" {
  capabilities = ["read"]
}

path "auth/approle/role/*/secret-id" {
  capabilities = ["update"]
}

path "auth/token/create" {
  capabilities = ["update"]
}

path "auth/token/create-orphan" {
  capabilities = ["update"]
}

# Needed for operator token-helper workflows that create/update reusable
# token roles and mint through them. This is broad, but still scoped to
# operator-* roles rather than arbitrary Vault roles.
path "auth/token/roles/operator-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}

path "auth/token/create/operator-*" {
  capabilities = ["update"]
}

# Helpful for cleanup/inspection of operator tokens by accessor.
path "auth/token/lookup-accessor" {
  capabilities = ["update"]
}

path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Needed by KV editor mount discovery.
path "sys/mounts" {
  capabilities = ["read"]
}

# Needed to detect KV v1 vs KV v2 without guessing.
path "sys/mounts/*/tune" {
  capabilities = ["read"]
}

# Helpful fallback for Vault UI-style mount discovery on restricted tokens.
path "sys/internal/ui/mounts" {
  capabilities = ["read"]
}

path "sys/policies/acl/operator-*" {
  capabilities = ["create", "update", "read", "delete", "list"]
}
EOF
}

write_direct_policy_for_choice() {
  local level="$1" project="$2" policy_file="$3" custom_source="${4:-}"
  self_policy > "$policy_file"
  printf '\n' >> "$policy_file"

  case "$level" in
    kv-read) kv_read_policy "$project" >> "$policy_file" ;;
    kv-write) kv_write_policy "$project" >> "$policy_file" ;;
    app-operator)
      kv_write_policy "$project" >> "$policy_file"
      printf '\n' >> "$policy_file"
      approle_policy "$project" >> "$policy_file"
      ;;
    platform-operator) platform_policy_body >> "$policy_file" ;;
    break-glass) break_glass_policy >> "$policy_file" ;;
    custom-file) cat "$custom_source" >> "$policy_file" ;;
    custom-editor)
      cat >> "$policy_file" <<'EOF'
# Add custom Vault ACL policy rules below.
# Self-management rules are already included above.

EOF
      "${EDITOR}" "$policy_file" < /dev/tty > /dev/tty
      ;;
    *) die "Unknown token level: $level" ;;
  esac
}

write_acl_policy() {
  trace_log "policy=$1"
  local policy_name="$1" hcl_file="$2" payload
  payload="$(mk_tmp_file)"
  jq -Rs '{policy:.}' < "$hcl_file" > "$payload"
  vault_api PUT "sys/policies/acl/${policy_name}" "$payload" >/dev/null
}

write_hcl_policy_from_text() {
  local policy_name="$1" hcl_file
  hcl_file="$(mk_tmp_file)"
  cat > "$hcl_file"
  write_acl_policy "$policy_name" "$hcl_file"
}

choose_output_file() {
  local label="$1" timestamp default_out out_file
  resolve_token_output_dir
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  default_out="${TOKEN_OUTPUT_DIR}/operator-token-${label}-${timestamp}.txt"
  out_file="$(ui_input "Output file" "Where should the newly minted token be written?

Default is the operator token-drop directory. Move it after retrieval, then delete the original." "$default_out")" || return 1
  [[ -n "$out_file" ]] || die "Output file cannot be empty"
  if [[ -L "$out_file" ]]; then
    die "Refusing to write token through symlink: $out_file"
  fi
  if [[ -e "$out_file" ]]; then
    ui_yesno "Overwrite file?" "Output file already exists. Overwrite it?\n\n$out_file" "no" || die "Cancelled"
  fi
  printf '%s' "$out_file"
}

create_token_payload() {
  local policy="$1" ttl="$2" display="$3" payload
  payload="$(mk_tmp_file)"
  jq -n \
    --arg policy "$policy" \
    --arg ttl "$ttl" \
    --arg display "$display" \
    '{policies:[$policy], ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:$display}' \
    > "$payload"
  printf '%s' "$payload"
}


# Create a token role that mints periodic, renewable break-glass tokens.
# This is intended for the "main operator token" use case where using the
# real root token repeatedly would be worse. The resulting token is still
# highly privileged, but it is not the root token, has an accessor, and can
# be revoked independently.
create_renewable_break_glass_role() {
  local role_name="$1" policy_name="$2" period="$3" explicit_max_ttl="$4" payload

  payload="$(mk_tmp_file)"
  jq -n \
    --arg policy "$policy_name" \
    --arg period "$period" \
    --arg max_ttl "$explicit_max_ttl" \
    '{
      allowed_policies: [$policy],
      disallowed_policies: ["root"],
      orphan: false,
      renewable: true,
      token_period: $period,
      token_explicit_max_ttl: $max_ttl,
      token_no_default_policy: false,
      token_num_uses: 0,
      token_type: "service"
    }' > "$payload"

  vault_api POST "auth/token/roles/${role_name}" "$payload" >/dev/null || return 1
}


# Create a non-renewable operator token role for one generated policy.
# This is the safe path for minting new policies from a break-glass/session
# token: Vault will reject direct child creation when the requested policy is
# not already a subset of the parent token, even if the parent can write that
# policy. Token roles are the intended delegation boundary for that case.
create_bounded_operator_token_role() {
  local role_name="$1" policy_name="$2" explicit_max_ttl="$3" payload

  payload="$(mk_tmp_file)"
  jq -n     --arg policy "$policy_name"     --arg max_ttl "$explicit_max_ttl"     '{
      allowed_policies: [$policy],
      disallowed_policies: ["root"],
      orphan: false,
      renewable: false,
      token_explicit_max_ttl: $max_ttl,
      token_no_default_policy: false,
      token_num_uses: 0,
      token_type: "service"
    }' > "$payload"

  vault_api POST "auth/token/roles/${role_name}" "$payload" >/dev/null || return 1
}

create_bounded_role_token_payload() {
  local policy="$1" ttl="$2" display="$3" payload
  payload="$(mk_tmp_file)"
  jq -n     --arg policy "$policy"     --arg ttl "$ttl"     --arg display "$display"     '{policies:[$policy], ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:$display}'     > "$payload"
  printf '%s' "$payload"
}

mint_bounded_role_token_to_file() {
  local role_name="$1" policy_name="$2" ttl="$3" display="$4" out_file="$5"
  local payload response token

  payload="$(create_bounded_role_token_payload "$policy_name" "$ttl" "$display")"
  response="$(vault_api POST "auth/token/create/${role_name}" "$payload")"
  token="$(extract_token_from_response "$response")"
  write_token_file "$token" "$out_file"
  unset token
}

mint_bounded_role_token_to_memory() {
  local role_name="$1" policy_name="$2" ttl="$3" display="$4"
  local payload response token

  payload="$(create_bounded_role_token_payload "$policy_name" "$ttl" "$display")"
  response="$(vault_api POST "auth/token/create/${role_name}" "$payload")"
  token="$(extract_token_from_response "$response")"
  printf '%s' "$token"
  unset token
}

# Mint a renewable token through a prepared token role and write it to a file.
# Returns token metadata on stdout as JSON. The token itself is only written
# to the requested output file.
mint_role_token_to_file() {
  local role_name="$1" policy_name="$2" display="$3" out_file="$4"
  local payload response token

  payload="$(mk_tmp_file)"
  jq -n \
    --arg policy "$policy_name" \
    --arg display "$display" \
    '{policies: [$policy], display_name: $display}' > "$payload"

  if ! response="$(vault_api POST "auth/token/create/${role_name}" "$payload")"; then
    return 1
  fi

  token="$(jq -er '.auth.client_token' <<< "$response")" || return 1
  write_token_file "$token" "$out_file" || return 1
  unset token

  jq '{
    accessor: (.auth.accessor // ""),
    policies: (.auth.policies // []),
    lease_duration: (.auth.lease_duration // 0),
    renewable: (.auth.renewable // false)
  }' <<< "$response"
}

# Save a non-secret companion metadata file beside a token file. This stores
# the token accessor, policy and role names so the operator can later find
# and revoke/renew/inspect without exposing the token in logs.
write_token_metadata_file() {
  local token_file="$1" policy_name="$2" role_name="$3" period="$4" max_ttl="$5" metadata_json="$6"
  local meta_file="${token_file}.metadata.json"

  if ! jq -e . >/dev/null 2>&1 <<< "$metadata_json"; then
    die "Refusing to write token metadata because token metadata was not valid JSON"
  fi

  jq -n \
    --arg policy "$policy_name" \
    --arg role "$role_name" \
    --arg period "$period" \
    --arg max_ttl "$max_ttl" \
    --argjson token_meta "$metadata_json" \
    '{
      policy: $policy,
      token_role: $role,
      renewal_period: $period,
      explicit_max_ttl: $max_ttl,
      token: $token_meta
    }' > "$meta_file"
  chmod 0600 "$meta_file"
}

# Read a single-line token from a file without printing it. This is used for
# token renewal. It deliberately does not support symlinks.
read_token_file_secret() {
  local token_file="$1"
  [[ -n "$token_file" ]] || die "Token file path cannot be empty"
  [[ -r "$token_file" ]] || die "Token file is not readable: $token_file"
  [[ ! -L "$token_file" ]] || die "Refusing to read token through symlink: $token_file"
  tr -d '\r\n' < "$token_file"
}

# Mint the older short-lived break-glass style token/session. This is meant for
# one-off emergency use when the operator needs broad capability briefly but does
# not want to create or maintain a renewable main token.
mint_short_lived_break_glass_impl() {
  local mode ttl label safe_label timestamp policy_name role_name policy_file out_file token typed

  ui_msg "Short-lived break-glass" "This creates a broad operator break-glass child token for short-term use.

Recommended shape:
- memory-only session when working inside this operator
- file output only when handing the token to another tool
- short TTL, usually 10m to 30m

This is not renewable and is intentionally separate from the reusable main break-glass token workflow."

  menu_reset
  menu_add "session" "Memory-only child session, auto-revoked on operator exit"
  menu_add "file" "Write short-lived child token to token-drop file"
  menu_add "back" "Cancel"
  mode="$(menu_choose "Short-lived break-glass" "Choose output shape")" || return 1
  [[ "$mode" == "back" ]] && return 0

  ttl="$(choose_duration "Break-glass duration" "10m")" || return 1
  label="$(ui_input "Label" "Short label for policy/output" "break-glass-${STACK_NAME:-operator}")" || return 1
  safe_label="$(safe_name "$label")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  policy_name="operator-break-glass-short-${safe_label}-${timestamp}"
  role_name="operator-break-glass-short-${safe_label}-${timestamp}"

  if ! token_can_short_break_glass; then
    ui_msg "Token lacks permissions" "The currently loaded token cannot mint a short-lived break-glass token.

Needed capabilities:
- create/update sys/policies/acl/operator-*
- create/update auth/token/roles/operator-*
- update auth/token/create/operator-*

This workflow uses an operator-scoped token role so the minted token can receive the newly-created policy without triggering Vault's child-policy subset rule. Use the real root token once, or an existing break-glass token minted with operator token-role management."
    return 1
  fi

  typed="$(ui_input "Confirm short-lived break-glass" "Create a broad short-lived break-glass child?

Policy: $policy_name
Role: $role_name
TTL: $ttl
Output mode: $mode

Type SHORT BREAK GLASS to continue:" "")" || return 1
  [[ "$typed" == "SHORT BREAK GLASS" ]] || die "Short-lived break-glass mint cancelled"

  policy_file="$(mk_tmp_file)"
  self_policy > "$policy_file"
  printf '
' >> "$policy_file"
  break_glass_policy >> "$policy_file"

  write_acl_policy "$policy_name" "$policy_file" || die "Failed to write short-lived break-glass policy"
  create_bounded_operator_token_role "$role_name" "$policy_name" "$ttl" || die "Failed to create short-lived break-glass token role"

  if [[ "$mode" == "session" ]]; then
    token="$(mint_bounded_role_token_to_memory "$role_name" "$policy_name" "$ttl" "operator-${safe_label}")"
    SESSION_TOKEN="$token"
    CURRENT_TOKEN="$SESSION_TOKEN"
    SESSION_TOKEN_MINTED=1
    SESSION_TOKEN_AUTO_REVOKE=1
    unset token
    ui_msg "Break-glass session started" "Short-lived break-glass session minted.

Policy: $policy_name
Role: $role_name
TTL: $ttl

This session is memory-only and will be revoked on operator exit."
  else
    out_file="$(choose_output_file "$safe_label")" || return 1
    mint_bounded_role_token_to_file "$role_name" "$policy_name" "$ttl" "operator-${safe_label}" "$out_file"
    ui_msg "Break-glass token created" "Short-lived break-glass token written to:

$out_file

Policy: $policy_name
Role: $role_name
TTL: $ttl

Move/grab it, then delete it from token-drop."
  fi
}

# Mint a longer-lived renewable broad operator token intended for repeated
# operator use. This is safer than reusing the real root token, but it is still
# powerful and should be protected like a break-glass credential.
mint_long_lived_break_glass_impl() {
  local period max_ttl label safe_label out_file policy_name role_name policy_file typed meta_json

  ui_msg "Renewable break-glass token" \
"This creates a reusable broad operator token without storing the real root token.\n\nRecommended shape:\n- short renewal period, such as 24h\n- explicit maximum lifetime, such as 30d\n- token file stored on tmpfs or another protected path\n\nThis should be treated as a main operator credential, not a casual daily token."

  period="$(choose_duration "Renewal period" "24h")" || return 1
  max_ttl="$(choose_duration "Explicit maximum lifetime" "30d")" || return 1
  label="$(ui_input "Label" "Short label for policy, role, and output filename" "main-break-glass-${STACK_NAME:-operator}")" || return 1
  safe_label="$(safe_name "$label")"

  policy_name="operator-break-glass-main-${safe_label}"
  role_name="operator-break-glass-main-${safe_label}"
  out_file="$(choose_output_file "$safe_label")" || return 1

  preflight_token_role_mint_permissions "$policy_name" "$role_name" || return 1

  typed="$(ui_input "Confirm renewable break-glass" \
"This creates a long-lived renewable broad operator token.\n\nPolicy: $policy_name\nRole: $role_name\nRenewal period: $period\nExplicit max lifetime: $max_ttl\nOutput: $out_file\n\nType RENEWABLE BREAK GLASS to continue:" "")" || return 1
  [[ "$typed" == "RENEWABLE BREAK GLASS" ]] || die "Renewable break-glass token mint cancelled"

  policy_file="$(mk_tmp_file)"
  self_policy > "$policy_file"
  printf '\n' >> "$policy_file"
  break_glass_policy >> "$policy_file"

  write_acl_policy "$policy_name" "$policy_file" || die "Failed to write break-glass policy. The supplied token likely lacks sys/policies/acl/operator-* create/update."
  create_renewable_break_glass_role "$role_name" "$policy_name" "$period" "$max_ttl" || die "Failed to create/update token role. The supplied token likely lacks auth/token/roles/operator-* create/update."

  if ! meta_json="$(mint_role_token_to_file "$role_name" "$policy_name" "operator-${safe_label}" "$out_file")"; then
    die "Failed to mint token through role ${role_name}. The supplied token likely lacks auth/token/create/${role_name} update, or the role was not created."
  fi

  write_token_metadata_file "$out_file" "$policy_name" "$role_name" "$period" "$max_ttl" "$meta_json"

  ui_msg "Renewable token created" \
"Renewable break-glass token written to:\n\n$out_file\n\nMetadata written to:\n${out_file}.metadata.json\n\nPolicy: $policy_name\nRole: $role_name\nRenewal period: $period\nExplicit max lifetime: $max_ttl\n\nRenew this token before each renewal period expires."
}

# Renew a token stored in a file. This is for the long-lived renewable token
# workflow. The token is read into memory temporarily and never printed.
renew_token_from_file() {
  local default_file token_file increment old_current token payload response ttl renewable

  resolve_token_output_dir
  default_file="${TOKEN_OUTPUT_DIR}/operator-token-main-break-glass.txt"
  token_file="$(ui_input "Renew token" "Path to token file to renew" "$default_file")" || return 1
  increment="$(choose_duration "Renewal increment" "24h")" || return 1

  token="$(read_token_file_secret "$token_file")"
  [[ -n "$token" ]] || die "Token file was empty"

  old_current="$CURRENT_TOKEN"
  CURRENT_TOKEN="$token"
  unset token

  payload="$(mk_tmp_file)"
  jq -n --arg increment "$increment" '{increment:$increment}' > "$payload"
  response="$(vault_api POST auth/token/renew-self "$payload")" || {
    CURRENT_TOKEN="$old_current"
    die "Token renewal failed"
  }

  CURRENT_TOKEN="$old_current"
  ttl="$(jq -r '.auth.lease_duration // 0' <<< "$response")"
  renewable="$(jq -r '.auth.renewable // false' <<< "$response")"

  ui_msg "Token renewed" \
"Token renewed successfully.\n\nFile: $token_file\nRequested increment: $increment\nLease duration seconds: $ttl\nRenewable: $renewable"
}

extract_token_from_response() {
  local response="$1"
  jq -er '.auth.client_token' <<< "$response"
}

write_token_file() {
  local token="$1" out_file="$2"

  if [[ -L "$out_file" ]]; then
    unset token
    die "Refusing to write token through symlink: $out_file"
  fi

  mkdir -p -- "$(dirname -- "$out_file")"
  : > "$out_file"
  chmod 0600 "$out_file"
  printf '%s\n' "$token" > "$out_file"
  chmod 0600 "$out_file"
}

create_token_to_file() {
  local endpoint="$1" policy="$2" ttl="$3" display="$4" out_file="$5" orphan="${6:-false}"
  local payload response token

  payload="$(create_token_payload "$policy" "$ttl" "$display")"

  if [[ "$orphan" == "true" ]]; then
    endpoint="auth/token/create-orphan"
  fi

  response="$(vault_api POST "$endpoint" "$payload")"
  token="$(extract_token_from_response "$response")"
  write_token_file "$token" "$out_file"
  unset token
}

create_token_to_memory() {
  local endpoint="$1" policy="$2" ttl="$3" display="$4" orphan="${5:-false}"
  local payload response token

  payload="$(create_token_payload "$policy" "$ttl" "$display")"

  if [[ "$orphan" == "true" ]]; then
    endpoint="auth/token/create-orphan"
  fi

  response="$(vault_api POST "$endpoint" "$payload")"
  token="$(extract_token_from_response "$response")"
  printf '%s' "$token"
  unset token
}

create_child_token_from_current_to_file() {
  local ttl label safe_label out_file policy_csv policies_json payload response token default_policies lookup orphan="false"
  ensure_session || return 1

  lookup="$(vault_lookup_self)" || die "Could not look up current token"
  default_policies="$(jq -r '(.data.policies // []) | map(select(. != "default" and . != "root")) | join(",")' <<< "$lookup")"
  [[ -n "$default_policies" ]] || default_policies="default"

  ttl="$(choose_duration "Child token duration" "30m")" || return 1
  label="$(ui_input "Label" "Short label for output filename" "child-${STACK_NAME:-operator}")" || return 1
  safe_label="$(safe_name "$label")"
  policy_csv="$(ui_input "Policies" "Comma-separated policies for the child token. This cannot exceed the current token's authority." "$default_policies")" || return 1

  if ui_yesno "Orphan token" "Create the child token as an orphan?\n\nNo is safer. Yes is only for deliberate handoff tokens." "no"; then
    orphan="true"
  fi

  if grep -Eq '(^|,) *root *(,|$)' <<< "$policy_csv"; then
    local root_confirm
    root_confirm="$(ui_input "Root child token" "You requested a child token with the root policy. Type MINT ROOT CHILD to continue." "")" || return 1
    [[ "$root_confirm" == "MINT ROOT CHILD" ]] || die "Root child token mint cancelled"
  fi

  out_file="$(choose_output_file "$safe_label")" || return 1
  policies_json="$(tr ',' '\n' <<< "$policy_csv" | sed 's/^ *//;s/ *$//' | awk 'NF' | jq -R . | jq -s '.')"

  payload="$(mk_tmp_file)"
  jq -n \
    --argjson policies "$policies_json" \
    --arg ttl "$ttl" \
    --arg display "operator-${safe_label}" \
    '{policies:$policies, ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:$display}' \
    > "$payload"

  local endpoint="auth/token/create"
  [[ "$orphan" == "true" ]] && endpoint="auth/token/create-orphan"

  response="$(vault_api POST "$endpoint" "$payload")"
  token="$(jq -er '.auth.client_token' <<< "$response")"

  if [[ -L "$out_file" ]]; then
    unset token
    die "Refusing to write token through symlink: $out_file"
  fi

  mkdir -p -- "$(dirname -- "$out_file")"
  : > "$out_file"
  chmod 0600 "$out_file"
  printf '%s\n' "$token" > "$out_file"
  chmod 0600 "$out_file"
  unset token

  ui_msg "Child token created" "Child token written to:\n\n$out_file\n\nTTL: $ttl\nPolicies: $policy_csv"
}

mint_root_derived_operator_token() {
  local old_current old_session old_minted old_auto
  local prompted_token lookup mode ttl label safe_label out_file token
  local policy_name policy_file timestamp

  ui_msg "Root-derived token" \
"This workflow uses a real root/admin token only long enough to mint a bounded child token.\n\nThe supplied root token is hidden, never written to disk, and cleared from memory after minting.\n\nRecommended mode: broad break-glass operator session, memory-only, auto-revoked on exit."

  prompted_token="$(ui_secret "Root/admin token" "Paste the real root/admin token. It will only be used for this mint operation.")" || return 1
  prompted_token="${prompted_token//$'\r'/}"
  prompted_token="${prompted_token//$'\n'/}"
  [[ -n "$prompted_token" ]] || die "Token cannot be empty"

  old_current="$CURRENT_TOKEN"
  old_session="$SESSION_TOKEN"
  old_minted="$SESSION_TOKEN_MINTED"
  old_auto="$SESSION_TOKEN_AUTO_REVOKE"

  if [[ -n "$old_session" ]]; then
    if ui_yesno "Replace active session" \
"A session token is already active. Revoke it before minting the new root-derived session/token?

Recommended: yes, so old privileged children do not remain active." "yes"; then
      CURRENT_TOKEN="$old_session"
      SESSION_TOKEN="$old_session"
      revoke_session_token || true
      old_current=""
      old_session=""
    else
      CURRENT_TOKEN="$old_current"
      unset prompted_token
      return 1
    fi
  fi

  CURRENT_TOKEN="$prompted_token"
  SUPPLIED_TOKEN=""
  lookup="$(vault_lookup_self)" || die "Root/admin token lookup failed"

  if ! token_has_root_policy "$lookup"; then
    ui_yesno "Token is not root" \
"The supplied token does not report the root policy. It may still have enough sudo/create-token capability, but this is not a true root-derived workflow.\n\nContinue anyway?" "no" || {
      CURRENT_TOKEN="$old_current"
      unset prompted_token
      return 1
    }
  fi

  menu_reset
  menu_add "break-glass-session" "Recommended: broad operator child, memory-only, auto-revoked"
  menu_add "break-glass-file" "Broad operator child token written to tmpfs file"
  menu_add "root-session" "Danger: actual root child, memory-only, auto-revoked"
  menu_add "root-file" "Danger: actual root child token written to tmpfs file"
  menu_add "back" "Cancel"
  mode="$(menu_choose "Root-derived child" "Choose the child token type")" || {
    CURRENT_TOKEN="$old_current"
    unset prompted_token
    return 1
  }

  case "$mode" in
    back)
      CURRENT_TOKEN="$old_current"
      unset prompted_token
      return 0
      ;;

    break-glass-session|break-glass-file)
      ttl="$(choose_duration "Break-glass child duration" "15m")" || return 1
      label="$(ui_input "Label" "Short label" "break-glass-${STACK_NAME:-operator}")" || return 1
      safe_label="$(safe_name "$label")"
      timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
      policy_name="operator-break-glass-${safe_label}-${timestamp}"
      policy_file="$(mk_tmp_file)"

      self_policy > "$policy_file"
      printf '\n' >> "$policy_file"
      break_glass_policy >> "$policy_file"

      if ! ui_yesno "Confirm broad child" \
"Create a broad break-glass operator child token?\n\nPolicy: $policy_name\nTTL: $ttl\nMode: $mode\n\nThis is powerful but not the real root token." "no"; then
        CURRENT_TOKEN="$old_current"
        unset prompted_token
        return 1
      fi

      write_acl_policy "$policy_name" "$policy_file"

      if [[ "$mode" == "break-glass-session" ]]; then
        token="$(create_token_to_memory "auth/token/create" "$policy_name" "$ttl" "operator-${safe_label}" "false")"
        SESSION_TOKEN="$token"
        CURRENT_TOKEN="$SESSION_TOKEN"
        SESSION_TOKEN_MINTED=1
        SESSION_TOKEN_AUTO_REVOKE=1
        unset token prompted_token
        ui_msg "Session started" \
"Broad break-glass child session minted.\n\nPolicy: $policy_name\nTTL: $ttl\n\nThe real root token was cleared from memory. This child session will be revoked on exit."
      else
        out_file="$(choose_output_file "$safe_label")" || return 1
        create_token_to_file "auth/token/create" "$policy_name" "$ttl" "operator-${safe_label}" "$out_file" "false"
        CURRENT_TOKEN="$old_current"
        unset prompted_token
        ui_msg "Token created" \
"Broad break-glass child token written to:\n\n$out_file\n\nPolicy: $policy_name\nTTL: $ttl\n\nThe real root token was cleared from memory."
      fi
      ;;

    root-session|root-file)
      ttl="$(choose_duration "Actual root child duration" "10m")" || return 1
      label="$(ui_input "Label" "Short label" "root-child-${STACK_NAME:-operator}")" || return 1
      safe_label="$(safe_name "$label")"

      local typed
      typed="$(ui_input "Confirm root child" \
"This creates an actual child token with the root policy. It is equivalent to root until it expires or is revoked.\n\nType MINT ROOT CHILD to continue:" "")" || return 1
      [[ "$typed" == "MINT ROOT CHILD" ]] || {
        CURRENT_TOKEN="$old_current"
        unset prompted_token
        die "Root child mint cancelled"
      }

      if [[ "$mode" == "root-session" ]]; then
        token="$(create_token_to_memory "auth/token/create" "root" "$ttl" "operator-${safe_label}" "false")"
        SESSION_TOKEN="$token"
        CURRENT_TOKEN="$SESSION_TOKEN"
        SESSION_TOKEN_MINTED=1
        SESSION_TOKEN_AUTO_REVOKE=1
        unset token prompted_token
        ui_msg "Root child session started" \
"Actual root child session minted.\n\nTTL: $ttl\n\nThe real root token was cleared from memory. This child session will be revoked on exit."
      else
        out_file="$(choose_output_file "$safe_label")" || return 1
        create_token_to_file "auth/token/create" "root" "$ttl" "operator-${safe_label}" "$out_file" "false"
        CURRENT_TOKEN="$old_current"
        unset prompted_token
        ui_msg "Root child token created" \
"Actual root child token written to:\n\n$out_file\n\nTTL: $ttl\n\nThe real root token was cleared from memory."
      fi
      ;;

    *)
      CURRENT_TOKEN="$old_current"
      unset prompted_token
      die "Unknown root-derived mode: $mode"
      ;;
  esac
}

run_with_prompted_token() {
  local purpose="$1" fn="$2" old_current old_supplied prompted_token
  shift 2
  old_current="$CURRENT_TOKEN"
  old_supplied="$SUPPLIED_TOKEN"

  if [[ -n "${VAULT_TOKEN_FILE:-}" ]]; then
    action_log "Read Vault token from configured token file for token-helper workflow"
    prompted_token="$(read_token_file_secret "$VAULT_TOKEN_FILE")"
  else
    prompted_token="$(ui_secret "Vault token" "$purpose")" || return 1
  fi

  prompted_token="${prompted_token//$'\r'/}"
  prompted_token="${prompted_token//$'\n'/}"
  [[ -n "$prompted_token" ]] || die "Token cannot be empty"
  CURRENT_TOKEN="$prompted_token"
  SUPPLIED_TOKEN=""
  validate_current_token
  local rc
  set +e
  "$fn" "$@"
  rc=$?
  set -e
  CURRENT_TOKEN="$old_current"
  SUPPLIED_TOKEN="$old_supplied"
  unset prompted_token
  return "$rc"
}


mint_direct_impl() {
  local level project ttl label safe_label timestamp policy_name role_name policy_file custom_policy_file out_file orphan="false"

  menu_reset
  menu_add "kv-read" "Read/list one KV project path"
  menu_add "kv-write" "Write/read one KV project path"
  menu_add "app-operator" "KV write plus AppRole secret-id for one project"
  menu_add "platform-operator" "Broad day-to-day ops for known stacks"
  menu_add "break-glass" "Very broad emergency token"
  menu_add "custom-file" "Load custom Vault ACL HCL from an existing file"
  menu_add "custom-editor" "Open editor to define custom Vault ACL HCL"
  level="$(menu_choose "Mint direct token" "Choose a preset or custom policy")" || return 1

  project=""
  custom_policy_file=""
  case "$level" in
    kv-read|kv-write|app-operator) project="$(select_project true)" ;;
    custom-file)
      custom_policy_file="$(ui_input "Custom policy file" "Path to existing Vault ACL HCL file" "/home/common/vault-v2/config/policies/operator.hcl")" || return 1
      [[ -r "$custom_policy_file" ]] || die "Policy file is not readable: $custom_policy_file"
      ;;
  esac

  case "$level" in
    kv-read) ttl="$(choose_duration "Token duration" "4h")" ;;
    kv-write) ttl="$(choose_duration "Token duration" "2h")" ;;
    app-operator) ttl="$(choose_duration "Token duration" "30m")" ;;
    platform-operator) ttl="$(choose_duration "Token duration" "30m")" ;;
    break-glass) ttl="$(choose_duration "Token duration" "10m")" ;;
    custom-file|custom-editor) ttl="$(choose_duration "Token duration" "30m")" ;;
  esac

  label="$(ui_input "Label" "Short label for the policy and output filename" "${level}${project:+-$project}")" || return 1
  safe_label="$(safe_name "$label")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  policy_name="operator-${safe_label}-${timestamp}"
  role_name="operator-${safe_label}-${timestamp}"
  policy_file="$(mk_tmp_file)"
  out_file="$(choose_output_file "$safe_label")" || return 1

  if ui_yesno "Orphan token" "Create the new token as an orphan?

This role-based mint path does not support orphan tokens. Choose No unless you intend to switch to the generic child-token workflow." "no"; then
    ui_msg "Orphan not supported here" "This workflow now mints through an operator token role to avoid Vault's child-policy subset rule. Orphan output is not supported on this path.

Use the generic child-token workflow if you specifically need an orphan child from the current token."
    orphan="false"
  fi

  if ! token_can_direct_scoped; then
    ui_msg "Token lacks permissions" "The selected authority token cannot mint a newly-scoped direct token with an operator-generated policy.

Needed capabilities:
- create/update sys/policies/acl/operator-*
- create/update auth/token/roles/operator-*
- update auth/token/create/operator-*

This role-based mint path avoids Vault's child-policy subset rule. Use the real root token once, or a break-glass token minted with operator token-role management."
    return 1
  fi

  write_direct_policy_for_choice "$level" "$project" "$policy_file" "$custom_policy_file"

  if ! ui_yesno "Confirm mint" "Create this token?

Policy: $policy_name
Role: $role_name
Level: $level
Project: ${project:-none}
TTL: $ttl
Output: $out_file" "yes"; then
    die "Cancelled"
  fi

  write_acl_policy "$policy_name" "$policy_file"
  create_bounded_operator_token_role "$role_name" "$policy_name" "$ttl"
  mint_bounded_role_token_to_file "$role_name" "$policy_name" "$ttl" "operator-${safe_label}" "$out_file"
  ui_msg "Done" "Operator token written to:

$out_file

Policy: $policy_name
Role: $role_name
Level: $level
TTL: $ttl"
}

delegate_policy_names_json() {
  local first=true p name
  printf '['
  for p in "${KNOWN_PROJECTS[@]}"; do
    for name in "operator-kv-read-${p}" "operator-kv-write-${p}" "operator-app-operator-${p}"; do
      if [[ "$first" == true ]]; then first=false; else printf ','; fi
      jq -Rn --arg name "$name" '$name'
    done
  done
  printf ','
  jq -Rn --arg name "$PLATFORM_POLICY" '$name'
  printf ']'
}

bootstrap_factory_impl() {
  local factory_ttl child_max_ttl out_file role_payload p allowed_json factory_role
  factory_ttl="$(choose_duration "Factory token duration" "30d")" || return 1
  child_max_ttl="$(choose_duration "Maximum delegated child-token duration" "24h")" || return 1
  out_file="$(choose_output_file "platform-token-factory")" || return 1

  if ! token_can_bootstrap_factory; then
    ui_msg "Token lacks permissions" "The selected authority token cannot bootstrap the platform factory workflow.

Needed capabilities:
- create/update sys/policies/acl/operator-*
- create/update auth/token/roles/operator-*
- update auth/token/create/operator-*

Use the real root token once, or a break-glass token minted with operator token-role management."
    return 1
  fi

  if ! ui_yesno "Confirm bootstrap" "Install reusable operator policies, create/update token role '${DELEGATE_ROLE}', and mint a longer-lived platform factory token?

Factory token TTL: $factory_ttl
Max child-token TTL: $child_max_ttl
Output: $out_file" "yes"; then
    die "Cancelled"
  fi

  for p in "${KNOWN_PROJECTS[@]}"; do
    write_hcl_policy_from_text "operator-kv-read-${p}" <<EOF
$(self_policy)

$(kv_read_policy "$p")
EOF
    write_hcl_policy_from_text "operator-kv-write-${p}" <<EOF
$(self_policy)

$(kv_write_policy "$p")
EOF
    write_hcl_policy_from_text "operator-app-operator-${p}" <<EOF
$(self_policy)

$(kv_write_policy "$p")

$(approle_policy "$p")
EOF
  done

  write_hcl_policy_from_text "$PLATFORM_POLICY" <<EOF
$(self_policy)

$(platform_policy_body)
EOF

  write_hcl_policy_from_text "$FACTORY_POLICY" <<EOF
$(self_policy)

$(platform_policy_body)

$(token_factory_body)
EOF

  allowed_json="$(delegate_policy_names_json)"
  role_payload="$(mk_tmp_file)"
  jq -n     --argjson allowed "$allowed_json"     --arg max_ttl "$child_max_ttl"     '{allowed_policies:$allowed, disallowed_policies:["root"], orphan:false, renewable:false, token_explicit_max_ttl:$max_ttl, token_no_default_policy:false, token_num_uses:0, token_type:"service"}'     > "$role_payload"

  vault_api POST "auth/token/roles/${DELEGATE_ROLE}" "$role_payload" >/dev/null

  factory_role="operator-platform-token-factory"
  create_bounded_operator_token_role "$factory_role" "$FACTORY_POLICY" "$factory_ttl"
  mint_bounded_role_token_to_file "$factory_role" "$FACTORY_POLICY" "$factory_ttl" "operator-platform-token-factory" "$out_file"

  ui_msg "Done" "Platform factory token written to:

$out_file

Policy: $FACTORY_POLICY
Factory role: $factory_role
Delegated role: $DELEGATE_ROLE
Factory TTL: $factory_ttl
Max child TTL: $child_max_ttl"
}

select_delegated_policy() {
  local level project policy
  menu_reset
  menu_add "kv-read" "Read/list one known KV project path"
  menu_add "kv-write" "Write/read one known KV project path"
  menu_add "app-operator" "KV write plus AppRole secret-id for one known project"
  menu_add "platform-operator" "Broad day-to-day ops, without minting powers"
  level="$(menu_choose "Delegated token" "Choose the weaker token type to mint")" || return 1
  case "$level" in
    kv-read) project="$(select_project false)"; policy="operator-kv-read-${project}" ;;
    kv-write) project="$(select_project false)"; policy="operator-kv-write-${project}" ;;
    app-operator) project="$(select_project false)"; policy="operator-app-operator-${project}" ;;
    platform-operator) project=""; policy="$PLATFORM_POLICY" ;;
    *) die "Unknown delegated level: $level" ;;
  esac
  printf '%s|%s|%s' "$level" "$project" "$policy"
}

mint_delegated_impl() {
  local selected level project policy ttl label safe_label out_file payload response token
  selected="$(select_delegated_policy)" || return 1
  level="${selected%%|*}"
  selected="${selected#*|}"
  project="${selected%%|*}"
  policy="${selected#*|}"

  ttl="$(choose_duration "Delegated token duration" "30m")" || return 1
  label="$(ui_input "Label" "Short label for output filename" "${level}${project:+-$project}")" || return 1
  safe_label="$(safe_name "$label")"
  out_file="$(choose_output_file "$safe_label")" || return 1

  if ! ui_yesno "Confirm delegated mint" "Create this delegated token?\n\nPolicy: $policy\nLevel: $level\nProject: ${project:-none}\nTTL: $ttl\nOutput: $out_file\n\nThis does not write ACL policies and does not require root." "yes"; then
    die "Cancelled"
  fi

  payload="$(mk_tmp_file)"
  jq -n \
    --arg policy "$policy" \
    --arg ttl "$ttl" \
    --arg display "operator-${safe_label}" \
    '{policies:[$policy], ttl:$ttl, explicit_max_ttl:$ttl, renewable:false, display_name:$display}' \
    > "$payload"

  response="$(vault_api POST "auth/token/create/${DELEGATE_ROLE}" "$payload")"
  token="$(jq -er '.auth.client_token' <<< "$response")"

  if [[ -L "$out_file" ]]; then unset token; die "Refusing to write token through symlink: $out_file"; fi
  mkdir -p -- "$(dirname -- "$out_file")"
  : > "$out_file"
  chmod 0600 "$out_file"
  printf '%s\n' "$token" > "$out_file"
  chmod 0600 "$out_file"
  unset token

  ui_msg "Done" "Delegated operator token written to:\n\n$out_file\n\nPolicy: $policy\nLevel: $level\nTTL: $ttl"
}

cleanup_token_output_file_flow() {
  local default_file token_file meta_file

  resolve_token_output_dir
  default_file="$TOKEN_OUTPUT_DIR/"
  token_file="$(ui_input "Delete token output" "Path to token file to delete after you have moved/grabbed it" "$default_file")" || return 1

  [[ -n "$token_file" ]] || die "Token file path cannot be empty"
  [[ "$token_file" != */ ]] || die "Choose a specific token file, not a directory"
  [[ ! -L "$token_file" ]] || die "Refusing to delete through symlink: $token_file"

  if [[ ! -e "$token_file" ]]; then
    ui_msg "Delete token output" "File does not exist:

$token_file"
    return 0
  fi

  meta_file="${token_file}.metadata.json"

  if ! ui_yesno "Confirm delete" "Delete this token file now?

$token_file

Metadata file will also be deleted if present:
$meta_file" "no"; then
    return 0
  fi

  # On tmpfs, rm is enough because the contents disappear from memory.
  # On disk-backed paths, shred is attempted first when available, then rm.
  if is_tmpfs_path "$(dirname -- "$token_file")"; then
    rm -f -- "$token_file" "$meta_file"
  else
    if have_cmd shred; then
      shred -u -- "$token_file" 2>/dev/null || rm -f -- "$token_file"
      [[ -e "$meta_file" ]] && shred -u -- "$meta_file" 2>/dev/null || rm -f -- "$meta_file" 2>/dev/null || true
    else
      rm -f -- "$token_file" "$meta_file"
    fi
  fi

  ui_msg "Deleted" "Removed token output file:

$token_file"
}

token_helper_menu() {
  trace_log "start"
  action_log "Open token helper"
  local mode prompt can_short can_renewable can_direct can_factory can_child can_delegated

  while true; do
    prompt="$(token_helper_prompt_summary)"

    can_short="$(token_helper_enabled_bool token_can_short_break_glass)"
    can_renewable="$(token_helper_enabled_bool token_can_renewable_break_glass)"
    can_direct="$(token_helper_enabled_bool token_can_direct_scoped)"
    can_factory="$(token_helper_enabled_bool token_can_bootstrap_factory)"
    can_child="$(token_helper_enabled_bool token_can_create_child)"
    can_delegated="$(token_helper_enabled_bool token_can_mint_delegate_role)"
    menu_reset
    # Power hierarchy: strongest and broadest workflows first, lower scoped
    # workflows later. Locked entries remain visible for operator context.
    menu_add "root-derived" "Highest power: use real root/admin briefly to mint bounded child"
    menu_add_power "renewable-break-glass" "Reusable renewable broad break-glass main token" "$can_renewable" "needs policy + operator role mint"
    menu_add_power "short-break-glass" "Short-lived broad break-glass token/session" "$can_short" "needs policy + operator role mint"
    menu_add_power "bootstrap-factory" "Install reusable policies and mint platform factory token" "$can_factory" "needs policy + operator role mint"
    menu_add_power "direct" "Mint scoped one-off token with custom/generated policy" "$can_direct" "needs policy + operator role mint"
    menu_add_power "child" "Mint child token from active/current token to file" "$can_child" "needs auth/token/create"
    menu_add_power "delegated" "Use factory token to mint weaker delegated token" "$can_delegated" "needs delegated token role"
    menu_add "session" "Start/restart short-lived in-memory operator session"
    menu_add "renew-file" "Renew token stored in file (uses that file token, not the menu token)"
    menu_add "delete-output" "Delete/move-cleanup a token output file"
    menu_add "back" "Back to main menu"

    mode="$(menu_choose "Token helper" "$prompt")" || return 0

    if menu_is_locked_choice "$mode"; then
      locked_choice_msg "$mode"
      continue
    fi

    case "$mode" in
      root-derived)
        mint_root_derived_operator_token
        ;;
      renewable-break-glass)
        run_workflow_with_current_or_prompt "Paste a root/admin Vault token. It will be used once to install the break-glass policy/token role and mint the renewable child token. The real root token is hidden and not written to disk." mint_long_lived_break_glass_impl || continue
        ;;
      short-break-glass)
        run_workflow_with_current_or_prompt "Paste a privileged Vault token. It needs to write an operator break-glass policy and create a short-lived child token. The token is hidden and not written to disk." mint_short_lived_break_glass_impl || continue
        ;;
      bootstrap-factory)
        run_workflow_with_current_or_prompt "Paste a root/admin Vault token. It is needed once to install reusable policies, create the token role, and mint the factory token." bootstrap_factory_impl || continue
        ;;
      direct)
        run_workflow_with_current_or_prompt "Paste a privileged Vault token. It must be able to write ACL policies and create tokens. The token is hidden and not written to disk." mint_direct_impl || continue
        ;;
      child)
        create_child_token_from_current_to_file
        ;;
      delegated)
        run_workflow_with_current_or_prompt "Paste the longer-lived platform factory token. It is hidden and not written to disk." mint_delegated_impl || continue
        ;;
      session)
        if [[ -n "$SESSION_TOKEN" ]]; then
          ui_yesno "Restart session" "A session already exists. Revoke it and start a new one?" "no" || continue
          revoke_session_token || true
          CURRENT_TOKEN=""
        fi
        mint_session_token
        ;;
      renew-file)
        renew_token_from_file
        ;;
      delete-output)
        cleanup_token_output_file_flow
        ;;
      back)
        return 0
        ;;
      *)
        ui_msg "Invalid" "Unknown token helper mode: $mode"
        ;;
    esac
  done
}

# =============================================================================
# KV helper functions
# =============================================================================

list_kv_mounts() {
  local resp mounts

  trace_log "discover KV mounts"

  if resp="$(vault_api GET sys/mounts 2>/dev/null)"; then
    mounts="$(jq -r '
      (.data // {})
      | to_entries[]?
      | select((.value | type) == "object")
      | select(.value.type == "kv")
      | .key
      | rtrimstr("/")
    ' <<< "$resp")" || mounts=""

    if [[ -n "$mounts" ]]; then
      printf '%s\n' "$mounts"
      return 0
    fi

    warn "sys/mounts returned no KV mounts or an unexpected response shape. Falling back to ${KV_DEFAULT_MOUNT}."
    printf '%s\n' "$KV_DEFAULT_MOUNT"
    return 0
  fi

  if resp="$(vault_api GET sys/internal/ui/mounts 2>/dev/null)"; then
    mounts="$(jq -r '
      (.data.secret // {})
      | to_entries[]?
      | select((.value | type) == "object")
      | select(.value.type == "kv")
      | .key
      | rtrimstr("/")
    ' <<< "$resp")" || mounts=""

    if [[ -n "$mounts" ]]; then
      printf '%s\n' "$mounts"
      return 0
    fi
  fi

  warn "Could not list Vault mounts with current token. Falling back to KV_DEFAULT_MOUNT=${KV_DEFAULT_MOUNT}."
  printf '%s\n' "$KV_DEFAULT_MOUNT"
}

choose_kv_mount() {
  local mounts choice m
  mounts="$(list_kv_mounts)" || die "Could not list KV mounts"
  [[ -n "$mounts" ]] || die "No KV mounts found"
  menu_reset
  while IFS= read -r m; do
    [[ -n "$m" ]] && menu_add "$m" "KV secrets engine"
  done <<< "$mounts"
  choice="$(menu_choose "KV mount" "Choose a KV mount")" || return 1
  printf '%s' "$choice"
}

kv_mount_version() {
  local mount="$1" resp version

  trace_log "mount=${mount}"

  if resp="$(vault_api GET "sys/mounts/${mount}/tune" 2>/dev/null)"; then
    version="$(jq -r '.data.options.version // "1"' <<< "$resp" 2>/dev/null || true)"
    [[ -n "$version" && "$version" != "null" ]] || version="1"
    printf '%s\n' "$version"
    return 0
  fi

  warn "Could not read tune data for mount '${mount}'. Falling back to KV_DEFAULT_VERSION=${KV_DEFAULT_VERSION}."
  printf '%s\n' "$KV_DEFAULT_VERSION"
}

list_kv_keys() {
  trace_log "mount=$1 prefix=$2"
  local mount="$1" prefix="$2" version list_path res
  version="$(kv_mount_version "$mount")" || return 1
  if [[ "$version" == "2" ]]; then
    list_path="${mount}/metadata/${prefix}"
  else
    list_path="${mount}/${prefix}"
  fi
  res="$(vault_api LIST "$list_path")" || return 1
  jq -r '.data.keys[]?' <<< "$res"
}

read_kv_secret() {
  trace_log "mount=$1 path=$2"
  local mount="$1" path="$2" version read_path res
  version="$(kv_mount_version "$mount")" || return 1
  if [[ "$version" == "2" ]]; then
    read_path="${mount}/data/${path}"
  else
    read_path="${mount}/${path}"
  fi
  res="$(vault_api GET "$read_path")" || return 1
  if [[ "$version" == "2" ]]; then
    jq -r '(.data.data // {}) | @json' <<< "$res"
  else
    jq -r '(.data // {}) | @json' <<< "$res"
  fi
}

write_kv_secret() {
  trace_log "mount=$1 path=$2"
  local mount="$1" path="$2" secret_json="$3" version write_path payload current_version meta
  version="$(kv_mount_version "$mount")" || return 1
  payload="$(mk_tmp_file)"
  if [[ "$version" == "2" ]]; then
    write_path="${mount}/data/${path}"
    current_version=0
    if meta="$(vault_api GET "${mount}/metadata/${path}" 2>/dev/null)"; then
      current_version="$(jq -r '.data.current_version // 0' <<< "$meta")"
    fi
    jq -n --argjson data "$secret_json" --argjson cas "$current_version" '{options:{cas:$cas},data:$data}' > "$payload"
  else
    write_path="${mount}/${path}"
    printf '%s\n' "$secret_json" > "$payload"
  fi
  vault_api POST "$write_path" "$payload" >/dev/null
}

redaction_level_label() {
  case "$REDACTION_LEVEL" in
    full) printf 'full redaction' ;;
    partial) printf 'partial redaction' ;;
    values) printf 'show values' ;;
    *) printf '%s' "$REDACTION_LEVEL" ;;
  esac
}

select_redaction_level() {
  local choice

  menu_reset
  menu_add "full" "Show keys only, values appear as <redacted>"
  menu_add "partial" "Show short hints only, useful for sanity checks"
  menu_add "values" "Show actual values in the KV editor"

  choice="$(menu_choose "Redaction level" "Current: $(redaction_level_label)\n\nChoose how KV values are displayed in the TUI.")" || return 1
  REDACTION_LEVEL="$choice"
  save_settings

  case "$REDACTION_LEVEL" in
    values)
      ui_msg "Redaction level" "KV editor will show actual secret values. Use this only on a trusted terminal and clear scrollback when done."
      ;;
    partial|full)
      ui_msg "Redaction level" "KV editor display mode changed to: $(redaction_level_label)"
      ;;
  esac
}

format_kv_secret_for_display() {
  local json="$1"

  jq -r --arg level "$REDACTION_LEVEL" '
    def clean_string:
      gsub("\r"; "\\r") | gsub("\n"; "\\n");

    def partial_string:
      clean_string as $s
      | if ($s | length) == 0 then
          "<empty string>"
        elif ($s | length) <= 8 then
          "<redacted:" + (($s | length) | tostring) + " chars>"
        else
          ($s[0:3] + "..." + $s[-3:] + " (" + (($s | length) | tostring) + " chars)")
        end;

    def render_value:
      if $level == "values" then
        if type == "string" then clean_string
        elif . == null then "null"
        else tojson
        end
      elif $level == "partial" then
        if type == "string" then partial_string
        elif . == null then "<null>"
        else "<redacted:" + type + ">"
        end
      else
        "<redacted>"
      end;

    if type != "object" then
      "  <non-object secret payload>"
    elif (keys_unsorted | length) == 0 then
      "  <empty>"
    else
      to_entries[]? | "  \(.key) = \(.value | render_value)"
    end
  ' <<< "$json"
}

normalize_kv_path_for_mount() {
  local mount="$1" raw="$2" path

  path="$(trim "$raw")"
  path="${path#/}"
  path="${path#${mount}/}"
  path="${path#data/}"
  path="${path#metadata/}"
  path="${path#/}"

  printf '%s' "$path"
}

kv_secret_path_from_prefix() {
  local prefix="$1"
  prefix="${prefix%/}"
  printf '%s' "$prefix"
}

kv_collect_secret_paths() {
  local mount="$1" prefix="$2" max_items="${3:-200}"
  local count=0
  local -a queue=()
  local current keys entry

  prefix="${prefix#/}"
  queue+=("$prefix")

  while (( ${#queue[@]} > 0 )); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")

    keys="$(list_kv_keys "$mount" "$current" 2>/dev/null || true)"
    [[ -n "$keys" ]] || continue

    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      if [[ "$entry" == */ ]]; then
        queue+=("${current}${entry}")
      else
        printf '%s%s
' "$current" "$entry"
        count=$((count + 1))
        if (( count >= max_items )); then
          warn "KV prefix report reached ${max_items} secrets. Results were truncated."
          return 0
        fi
      fi
    done <<< "$keys"
  done
}

kv_secret_report() {
  local mount="$1" path="$2" title_path secret_json

  path="${path#/}"
  path="$(kv_secret_path_from_prefix "$path")"
  title_path="${path:-/}"

  printf 'Secret: %s/%s
' "$mount" "$title_path"
  printf 'Display: %s

' "$(redaction_level_label)"

  if [[ -z "$path" ]]; then
    printf '  <mount root is not a secret path; choose a child secret or inspect a prefix>
'
    return 0
  fi

  if secret_json="$(read_kv_secret "$mount" "$path" 2>/dev/null)"; then
    format_kv_secret_for_display "$secret_json"
  else
    printf '  <could not read this secret; it may not exist, may be a folder only, or the token lacks read permission>
'
  fi
}

kv_prefix_report() {
  local mount="$1" prefix="$2" max_items="${3:-200}"
  local cleaned direct_secret paths path secret_json count=0

  cleaned="$(normalize_kv_path_for_mount "$mount" "$prefix")"

  printf 'KV prefix report
'
  printf 'Mount: %s
' "$mount"
  printf 'Prefix: %s
' "${cleaned:-/}"
  printf 'Display: %s
' "$(redaction_level_label)"
  printf 'Limit: %s secrets

' "$max_items"

  direct_secret="$(kv_secret_path_from_prefix "$cleaned")"
  if [[ -n "$direct_secret" ]] && secret_json="$(read_kv_secret "$mount" "$direct_secret" 2>/dev/null)"; then
    printf '## %s/%s
' "$mount" "$direct_secret"
    format_kv_secret_for_display "$secret_json"
    printf '
'
    count=$((count + 1))
  fi

  if [[ -n "$cleaned" && "$cleaned" != */ ]]; then
    cleaned="${cleaned}/"
  fi

  paths="$(kv_collect_secret_paths "$mount" "$cleaned" "$max_items" 2>/dev/null || true)"
  if [[ -n "$paths" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      [[ "$path" == "$direct_secret" ]] && continue
      printf '## %s/%s
' "$mount" "$path"
      if secret_json="$(read_kv_secret "$mount" "$path" 2>/dev/null)"; then
        format_kv_secret_for_display "$secret_json"
      else
        printf '  <read failed>
'
      fi
      printf '
'
      count=$((count + 1))
      (( count >= max_items )) && break
    done <<< "$paths"
  fi

  if (( count == 0 )); then
    printf 'No readable secrets were found at or below this prefix.
'
    printf '
Checks to try:
'
    printf '  - Use the path relative to the mount, for example arcane instead of kv/arcane.
'
    printf '  - If this is KV v2, the script handles data/ and metadata/ automatically.
'
    printf '  - Confirm the token has list on %s/metadata/%s and read on %s/data/%s*.
' "$mount" "$cleaned" "$mount" "$cleaned"
  fi
}

show_kv_secret_report() {
  local mount="$1" path="$2" report
  action_log "View KV secret fields: ${mount}/${path}"
  report="$(kv_secret_report "$mount" "$path")"
  ui_textbox "KV secret fields" "$report" || true
  return 0
}

show_kv_prefix_report() {
  local mount="$1" prefix="$2" report
  action_log "Inspect KV prefix: ${mount}/${prefix:-/}"
  report="$(kv_prefix_report "$mount" "$prefix")"
  ui_textbox "KV prefix report" "$report" || true
  return 0
}

select_existing_kv_field() {
  local json="$1" title="${2:-KV key}" key choice
  local keys

  keys="$(jq -r 'if type == "object" then keys_unsorted[]? else empty end' <<< "$json")"
  if [[ -z "$keys" ]]; then
    ui_msg "$title" "This secret has no keys yet."
    return 1
  fi

  menu_reset
  while IFS= read -r key; do
    [[ -n "$key" ]] && menu_add "$key" "existing field"
  done <<< "$keys"
  menu_add "manual" "Type a key name"

  choice="$(menu_choose "$title" "Choose a field")" || return 1
  if [[ "$choice" == "manual" ]]; then
    ui_input "$title" "Key name" ""
  else
    printf '%s' "$choice"
  fi
}

edit_kv_secret() {
  local mount="$1" path="$2" secret_json updated_json choice key value diff_msg key_count

  trace_log "mount=${mount} path=${path}"
  action_log "Edit KV secret: ${mount}/${path}"

  path="$(normalize_kv_path_for_mount "$mount" "$path")"
  path="$(kv_secret_path_from_prefix "$path")"
  [[ -n "$path" ]] || { ui_msg "Invalid path" "Secret path cannot be empty."; return 1; }

  if ! secret_json="$(read_kv_secret "$mount" "$path" 2>/dev/null)"; then
    if ui_yesno "Read failed" "Could not read ${mount}/${path}.

This may mean the secret does not exist, the path is a folder only, or the current token lacks read permission.

Continue with an empty secret and attempt to create/write it?" "no"; then
      secret_json="{}"
    else
      return 1
    fi
  fi

  updated_json="$secret_json"

  while true; do
    key_count="$(jq -r 'if type == "object" then (keys_unsorted | length) else 0 end' <<< "$updated_json")"
    diff_msg="Secret: ${mount}/${path}
Display: $(redaction_level_label)
Fields: ${key_count}

Use View fields for a scrollable list of all keys and values for this secret."

    menu_reset
    menu_add "view" "View all fields in this secret"
    menu_add "set" "Add or update a field"
    menu_add "delete" "Delete a field"
    menu_add "redaction" "Change value display redaction"
    menu_add "save" "Save changes"
    menu_add "back" "Back to KV browser, discarding unsaved changes"

    choice="$(menu_choose "Edit KV secret" "$diff_msg")" || continue
    case "$choice" in
      view)
        ui_textbox "KV secret fields" "Current secret: ${mount}/${path}
Display: $(redaction_level_label)

$(format_kv_secret_for_display "$updated_json")" || true
        ;;
      set)
        if [[ "$key_count" != "0" ]] && ui_yesno "KV field" "Update an existing field?

Choose No to type a new field name." "yes"; then
          key="$(select_existing_kv_field "$updated_json" "Update field" || true)"
        else
          key=""
        fi
        if [[ -z "$key" ]]; then
          key="$(ui_input "KV field" "Field name" "")" || continue
        fi
        [[ -n "$key" ]] || { ui_msg "Invalid" "Field name cannot be empty."; continue; }
        value="$(ui_secret "KV value" "Value for field '$key'")" || continue
        updated_json="$(jq --arg k "$key" --arg v "$value" '. + {($k):$v}' <<< "$updated_json")"
        ;;
      delete)
        key="$(select_existing_kv_field "$updated_json" "Delete field" || true)"
        [[ -n "$key" ]] || continue
        updated_json="$(jq --arg k "$key" 'del(.[$k])' <<< "$updated_json")"
        ;;
      redaction)
        select_redaction_level || true
        ;;
      save)
        if ui_yesno "Save secret" "Write updated secret to ${mount}/${path}?" "no"; then
          write_kv_secret "$mount" "$path" "$updated_json" || { ui_msg "Error" "Failed to write secret."; return 1; }
          ui_msg "Saved" "Secret saved: ${mount}/${path}"
          return 0
        fi
        ;;
      back|cancel)
        if [[ "$updated_json" != "$secret_json" ]]; then
          ui_yesno "Discard changes?" "Discard unsaved changes and return to the KV browser?" "no" || continue
        fi
        return 0
        ;;
    esac
  done
}

kv_edit_flow() {
  trace_log "start"
  action_log "Open KV editor"
  ensure_session || return 1

  local mount prefix keys choice entry fullpath newpath list_failed manual_default list_status

  mount="$(choose_kv_mount)" || return 1
  prefix=""

  while true; do
    list_failed=0
    if ! keys="$(list_kv_keys "$mount" "$prefix" 2>/dev/null)"; then
      keys=""
      list_failed=1
      warn "Could not list KV keys at ${mount}/${prefix:-/}. You can still inspect or enter a path manually."
    fi

    menu_reset
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      if [[ "$entry" == */ ]]; then
        menu_add "$entry" "folder"
      else
        menu_add "$entry" "secret"
      fi
    done <<< "$keys"

    menu_add "inspect" "Show all readable secrets and fields below this prefix"
    menu_add "view-path" "View one secret by path"
    menu_add "edit-path" "Create or edit a secret by path"
    [[ -n "$prefix" ]] && menu_add "up" "Go up one level"
    menu_add "mount" "Choose another mount"
    menu_add "back" "Back to main menu"

    if [[ "$list_failed" == "1" ]]; then
      list_status="list failed or denied"
    else
      list_status="ok"
    fi

    choice="$(menu_choose "KV browser" "Mount: $mount
Prefix: ${prefix:-/}
List status: ${list_status}
Display: $(redaction_level_label)

Choose a key or action")" || continue
    case "$choice" in
      inspect)
        show_kv_prefix_report "$mount" "$prefix" || true
        ;;
      view-path)
        manual_default="${prefix%/}"
        newpath="$(ui_input "KV path" "Secret path. Examples: arcane, arcane/db, kv/arcane, kv/data/arcane." "$manual_default")" || continue
        newpath="$(normalize_kv_path_for_mount "$mount" "$newpath")"
        [[ -n "$newpath" ]] && show_kv_secret_report "$mount" "$newpath" || true
        ;;
      edit-path)
        manual_default="${prefix%/}"
        newpath="$(ui_input "KV path" "Path relative to mount. For a secret at a folder root, omit the trailing slash." "$manual_default")" || continue
        newpath="$(normalize_kv_path_for_mount "$mount" "$newpath")"
        [[ -n "$newpath" ]] && edit_kv_secret "$mount" "$newpath" || true
        ;;
      up)
        action_log "KV browser: go up from ${mount}/${prefix:-/}"
        prefix="${prefix%/}"
        prefix="${prefix%/*}"
        [[ -n "$prefix" ]] && prefix="${prefix}/"
        ;;
      mount)
        action_log "KV browser: choose another mount"
        mount="$(choose_kv_mount)" || continue
        prefix=""
        ;;
      back)
        return 0
        ;;
      */)
        action_log "KV browser: enter prefix ${mount}/${prefix}${choice}"
        prefix="${prefix}${choice}"
        ;;
      *)
        fullpath="${prefix}${choice}"
        edit_kv_secret "$mount" "$fullpath" || true
        ;;
    esac
  done
}

# =============================================================================
# AppRole rendering
# =============================================================================

approle_render_flow() {
  trace_log "start"
  action_log "Render AppRole auth files"
  ensure_session || return 1
  local default_role role default_out outdir role_id resp sid_resp secret_id stage
  default_role="${VAULT_APPROLE_NAME:-${STACK_NAME:-}}"
  default_out="${REPO_ROOT}/runtime/vault-auth"
  role="$(ui_input "AppRole" "AppRole role name" "$default_role")" || return 1
  [[ -n "$role" ]] || { ui_msg "Invalid" "Role name cannot be empty."; return 1; }
  outdir="$(ui_input "AppRole destination" "Output directory for role_id and secret_id" "$default_out")" || return 1
  [[ -n "$outdir" ]] || { ui_msg "Invalid" "Output directory cannot be empty."; return 1; }

  sanitize_abs_path "$outdir" || { ui_msg "Invalid path" "Destination must be an absolute path without control characters."; return 1; }
  if [[ -L "$outdir" ]]; then
    ui_msg "Unsafe path" "Refusing to write AppRole files into a symlinked directory."
    return 1
  fi

  require_capabilities "auth/approle/role/${role}/role-id" read || return 1
  require_capabilities "auth/approle/role/${role}/secret-id" update || return 1

  resp="$(vault_api GET "auth/approle/role/${role}/role-id")" || { ui_msg "Error" "Failed to read role_id."; return 1; }
  role_id="$(jq -r '.data.role_id // empty' <<< "$resp")"
  [[ -n "$role_id" ]] || { ui_msg "Error" "Could not parse role_id."; return 1; }

  sid_resp="$(vault_api POST "auth/approle/role/${role}/secret-id")" || { ui_msg "Error" "Failed to create secret_id."; return 1; }
  secret_id="$(jq -r '.data.secret_id // empty' <<< "$sid_resp")"
  [[ -n "$secret_id" ]] || { ui_msg "Error" "Could not parse secret_id."; return 1; }

  mkdir -p -- "$outdir"
  chmod 0700 "$outdir"
  [[ ! -L "$outdir/role_id" ]] || die "Refusing to overwrite symlink: $outdir/role_id"
  [[ ! -L "$outdir/secret_id" ]] || die "Refusing to overwrite symlink: $outdir/secret_id"
  stage="$(mk_tmp_file)"
  printf '%s\n' "$role_id" > "$stage.role_id"
  printf '%s\n' "$secret_id" > "$stage.secret_id"
  chmod 0400 "$stage.role_id" "$stage.secret_id"
  mv -- "$stage.role_id" "$outdir/role_id"
  mv -- "$stage.secret_id" "$outdir/secret_id"
  chmod 0400 "$outdir/role_id" "$outdir/secret_id"
  unset secret_id role_id
  ui_msg "AppRole rendered" "role_id and secret_id written to:\n\n$outdir"
}

# =============================================================================
# Docker-aware Prime01 stack diagnostic helpers
# =============================================================================

# Docker-aware mode is intentionally not a generic Docker browser. It is a
# read-only Prime01 stack diagnostic browser focused on the relationship between:
#   - Docker Compose stack identity
#   - Vault Agent auth files
#   - Vault Agent rendered secret files
#   - app-container secret visibility
#   - runtime mount permissions
#   - legacy path drift from earlier stack layouts
#
# Rule of thumb:
#   Menus are for choices. Reports are for information.
#   Keep menus short, then open aligned scrollable reports for details.

docker_require_available() {
  trace_log "start"

  if ! have_cmd docker; then
    ui_msg "Docker unavailable" "Docker is not installed or is not in PATH. Install/configure Docker before using Docker-aware mode."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    ui_msg "Docker unavailable" "Docker is installed, but the daemon is not reachable from this user/session. Try running the operator with sudo or check Docker service status."
    return 1
  fi
}

docker_run() {
  # One wrapper for Docker calls so tracing and future policy checks stay DRY.
  trace_log "$*"
  docker "$@"
}

docker_names() {
  docker_run ps --format '{{.Names}}' 2>/dev/null || true
}

docker_inspect_one_json() {
  local cname="$1"
  docker_run inspect "$cname" 2>/dev/null | jq '.[0]'
}

docker_label() {
  local cname="$1" label="$2"
  docker_inspect_one_json "$cname" | jq -r --arg label "$label" '.Config.Labels[$label] // ""' 2>/dev/null || true
}

docker_state() {
  local cname="$1"
  docker_inspect_one_json "$cname" | jq -r '.State.Status // "unknown"' 2>/dev/null || printf 'unknown'
}

docker_health() {
  local cname="$1"
  docker_inspect_one_json "$cname" | jq -r '.State.Health.Status // "none"' 2>/dev/null || printf 'unknown'
}

docker_image() {
  local cname="$1"
  docker_inspect_one_json "$cname" | jq -r '.Config.Image // .Image // "unknown"' 2>/dev/null || printf 'unknown'
}

docker_user() {
  local cname="$1" user
  user="$(docker_inspect_one_json "$cname" | jq -r '.Config.User // ""' 2>/dev/null || true)"
  [[ -n "$user" ]] && printf '%s' "$user" || printf 'image-default'
}

docker_service() {
  local cname="$1" service
  service="$(docker_label "$cname" 'com.docker.compose.service')"
  [[ -n "$service" ]] && printf '%s' "$service" || printf 'unlabeled'
}

docker_project() {
  local cname="$1" project
  project="$(docker_label "$cname" 'com.docker.compose.project')"
  [[ -n "$project" ]] && printf '%s' "$project" || printf 'unlabeled'
}

docker_working_dir() {
  local cname="$1"
  docker_label "$cname" 'com.docker.compose.project.working_dir'
}

docker_container_role() {
  local cname="$1" service image haystack
  service="$(docker_service "$cname")"
  image="$(docker_image "$cname")"
  haystack="${cname,,} ${service,,} ${image,,}"

  case "$haystack" in
    *vault-agent*|*vault_agent*) printf 'vault-agent' ;;
    *tailscale*|*ts-sidecar*|*ts_sidecar*) printf 'tailscale' ;;
    *postgres*|*mariadb*|*mysql*|*redis*|*database*|*db*) printf 'data' ;;
    *traefik*|*proxy*) printf 'proxy' ;;
    *headscale*) printf 'control' ;;
    *) printf 'app/support' ;;
  esac
}

docker_clip() {
  local value="$1" width="$2"
  if (( ${#value} > width )); then
    printf '%s…' "${value:0:$((width - 1))}"
  else
    printf '%s' "$value"
  fi
}

docker_status_word() {
  local state="$1" health="$2"
  if [[ "$state" != "running" ]]; then
    printf 'FAIL'
  elif [[ "$health" == "unhealthy" ]]; then
    printf 'FAIL'
  elif [[ "$health" == "starting" ]]; then
    printf 'WARN'
  else
    printf 'OK'
  fi
}

docker_stack_names() {
  local cname project
  {
    while IFS= read -r cname; do
      [[ -n "$cname" ]] || continue
      project="$(docker_project "$cname")"
      [[ -n "$project" && "$project" != "unlabeled" ]] && printf '%s\n' "$project"
    done < <(docker_names)

    if [[ -r "$STACKS_FILE" ]]; then
      jq -r '.stacks[]?.id // empty' "$STACKS_FILE" 2>/dev/null || true
    fi
  } | awk 'NF && !seen[$0]++ {print}' | sort
}

docker_stack_root() {
  local stack="$1" root="" cname working_dir

  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    if [[ "$(docker_project "$cname")" == "$stack" ]]; then
      working_dir="$(docker_working_dir "$cname")"
      if [[ -n "$working_dir" ]]; then
        printf '%s' "$working_dir"
        return 0
      fi
    fi
  done < <(docker_names)

  if [[ -r "$STACKS_FILE" ]]; then
    root="$(jq -r --arg stack "$stack" '.stacks[]? | select(.id == $stack) | .root // empty' "$STACKS_FILE" 2>/dev/null | head -n 1)"
  fi

  [[ -n "$root" ]] && printf '%s' "$root" || printf '/home/common/%s' "$stack"
}

docker_stack_container_names() {
  local stack="$1" cname project
  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    project="$(docker_project "$cname")"
    [[ "$project" == "$stack" ]] && printf '%s\n' "$cname"
  done < <(docker_names)
}

docker_stack_vault_agents() {
  local stack="$1" cname role
  while IFS= read -r cname; do
    role="$(docker_container_role "$cname")"
    [[ "$role" == "vault-agent" ]] && printf '%s\n' "$cname"
  done < <(docker_stack_container_names "$stack")
}

docker_stack_app_containers() {
  local stack="$1" cname role
  while IFS= read -r cname; do
    role="$(docker_container_role "$cname")"
    case "$role" in
      vault-agent|tailscale|data) ;;
      *) printf '%s\n' "$cname" ;;
    esac
  done < <(docker_stack_container_names "$stack")
}

docker_exec_test() {
  local cname="$1" test_flag="$2" cpath="$3"
  docker_run exec "$cname" test "$test_flag" "$cpath" >/dev/null 2>&1
}

docker_exec_stat_line() {
  local cname="$1" cpath="$2"
  docker_run exec "$cname" stat -c '%A %U:%G %s %n' "$cpath" 2>/dev/null \
    || docker_run exec "$cname" ls -ld "$cpath" 2>/dev/null \
    || printf 'missing/unreadable %s' "$cpath"
}

docker_dir_file_count() {
  local cname="$1" cpath="$2"
  docker_exec_test "$cname" -d "$cpath" || { printf '0'; return 0; }
  docker_run exec "$cname" find "$cpath" -type f -maxdepth 4 2>/dev/null | wc -l | tr -d ' '
}

docker_dir_listing_report() {
  local cname="$1" cpath="$2" maxdepth="${3:-3}"

  if ! docker_exec_test "$cname" -e "$cpath"; then
    printf '  %-32s %s\n' "$cpath" 'missing'
    return 0
  fi

  docker_run exec "$cname" find "$cpath" -maxdepth "$maxdepth" -printf '%M %u:%g %s %p\n' 2>/dev/null \
    || docker_run exec "$cname" ls -la "$cpath" 2>/dev/null \
    || printf '  unable to list %s\n' "$cpath"
}

docker_redact_output() {
  sed -E \
    -e 's/(hvs\.|hvb\.|hvr\.|s\.)[A-Za-z0-9._=-]{8,}/<redacted-token>/g' \
    -e 's/([A-Za-z_]*(token|secret|password|authkey|auth_key)[A-Za-z_]*[=:][[:space:]]*)[^[:space:]]+/\1<redacted>/Ig' \
    -e 's/(client_token"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/Ig' \
    -e 's/(secret_id"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/Ig'
}

docker_path_status_line() {
  local cname="$1" label="$2" cpath="$3" kind="${4:-file}" exists="FAIL" readable="FAIL" stat_line

  if docker_exec_test "$cname" -e "$cpath"; then
    exists="OK"
  fi

  case "$kind" in
    dir)
      docker_exec_test "$cname" -d "$cpath" && readable="OK" || readable="FAIL"
      ;;
    file)
      docker_exec_test "$cname" -r "$cpath" && readable="OK" || readable="FAIL"
      ;;
    any)
      docker_exec_test "$cname" -r "$cpath" && readable="OK" || readable="$exists"
      ;;
  esac

  stat_line="$(docker_exec_stat_line "$cname" "$cpath")"
  printf '  %-22s %-6s %-8s %-52s %s\n' "$label" "$exists" "$readable" "$cpath" "$stat_line"
}

docker_mounts_table() {
  local cname="$1"
  printf '  %-6s %-62s %-34s %-4s\n' 'Type' 'Host source' 'Container path' 'Mode'
  printf '  %-6s %-62s %-34s %-4s\n' '----' '-----------' '--------------' '----'
  docker_inspect_one_json "$cname" | jq -r '
    .Mounts[]? |
    [.Type, (.Source // ""), (.Destination // ""), (if .RW then "rw" else "ro" end)] | @tsv
  ' 2>/dev/null | while IFS=$'\t' read -r mtype source dest mode; do
    printf '  %-6s %-62s %-34s %-4s\n' \
      "$(docker_clip "$mtype" 6)" \
      "$(docker_clip "$source" 62)" \
      "$(docker_clip "$dest" 34)" \
      "$mode"
  done
}

docker_mounts_legacy_warnings() {
  local cname="$1"
  docker_inspect_one_json "$cname" | jq -r '
    .Mounts[]? |
    select((.Source // "" | test("/config/|/output-secrets|/secrets-old|/old")) or (.Destination // "" | test("/vault/output-secrets|/output-secrets"))) |
    "  WARN legacy/suspicious mount: " + (.Source // "") + " -> " + (.Destination // "")
  ' 2>/dev/null || true
}

docker_vault_agent_config_hints() {
  local cname="$1"

  if docker_exec_test "$cname" -r /vault/config/agent.hcl; then
    docker_run exec "$cname" sh -c "grep -nE '^[[:space:]]*(address|role_id_file_path|secret_id_file_path|exit_after_auth|template|source|destination|command|perms|static_secret_render_interval)' /vault/config/agent.hcl 2>/dev/null || true" \
      | docker_redact_output
  else
    printf '  /vault/config/agent.hcl is not readable or not mounted at the standard path.\n'
  fi
}

docker_vault_agent_report() {
  local cname="$1" state health service image user files_count legacy

  state="$(docker_state "$cname")"
  health="$(docker_health "$cname")"
  service="$(docker_service "$cname")"
  image="$(docker_image "$cname")"
  user="$(docker_user "$cname")"
  files_count="$(docker_dir_file_count "$cname" /vault/secrets)"
  legacy="$(docker_mounts_legacy_warnings "$cname")"

  cat <<EOF
Vault Agent relationship report
===============================

Container:    $cname
Service:      $service
Image:        $image
User:         $user
State:        $state
Health:       $health
Rendered:     $files_count file(s) under /vault/secrets

Standard path checks
--------------------
$(docker_path_status_line "$cname" 'role_id' /vault/auth/role_id file)
$(docker_path_status_line "$cname" 'secret_id' /vault/auth/secret_id file)
$(docker_path_status_line "$cname" 'agent config' /vault/config/agent.hcl file)
$(docker_path_status_line "$cname" 'secrets dir' /vault/secrets dir)

Mounts
------
$(docker_mounts_table "$cname")

Suspicious path drift
---------------------
${legacy:-  OK no obvious legacy/output-secret mounts found}

Agent config hints, values redacted
-----------------------------------
$(docker_vault_agent_config_hints "$cname")

Rendered file listing, names and metadata only
---------------------------------------------
$(docker_dir_listing_report "$cname" /vault/secrets 4)

Recent Vault Agent logs, redacted
---------------------------------
$(docker_run logs --tail 80 "$cname" 2>&1 | docker_redact_output || true)
EOF
}

docker_app_secret_visibility_report() {
  local stack="$1" cname state health role any=0

  cat <<EOF
App/container rendered secret visibility
========================================

Stack: $stack

This report checks common in-container secret paths without printing secret values.
It tells you whether app/support containers can see the files Vault Agent rendered.

EOF

  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    any=1
    role="$(docker_container_role "$cname")"
    state="$(docker_state "$cname")"
    health="$(docker_health "$cname")"
    cat <<EOF
Container: $cname
Role:      $role
State:     $state
Health:    $health

Common secret path checks
-------------------------
$(docker_path_status_line "$cname" '/run/stack-secrets' /run/stack-secrets dir)
$(docker_path_status_line "$cname" '/vault/secrets' /vault/secrets dir)
$(docker_path_status_line "$cname" '/run/secrets' /run/secrets dir)

/run/stack-secrets listing, names and metadata only
--------------------------------------------------
$(docker_dir_listing_report "$cname" /run/stack-secrets 3)

EOF
  done < <(docker_stack_app_containers "$stack")

  if [[ "$any" == "0" ]]; then
    cat <<EOF
No app/support containers were detected for this stack. If this is unexpected,
check compose labels and container naming.
EOF
  fi
}


# =============================================================================
# Read-only Vault contract and key-usage diagnostics
# =============================================================================

# These helpers intentionally do not write to Vault or Docker. They compare the
# stack's declared/templated Vault contract with what the operator can read.
# "Unused" here means "not referenced by the registry contract or templates that
# this script can inspect". It is not proof that the application never reads it.

contract_registry_expected_keys() {
  local stack="$1"
  [[ -r "$STACKS_FILE" ]] || return 0
  jq -r --arg stack "$stack" '
    .stacks[]? |
    select((.id // "") == $stack) |
    ((.vault.expected_keys[]? // empty), (.expected_keys[]? // empty))
  ' "$STACKS_FILE" 2>/dev/null | awk 'NF && !seen[$0]++ {print}' | sort
}

contract_registry_kv_paths() {
  local stack="$1"
  [[ -r "$STACKS_FILE" ]] || return 0
  jq -r --arg stack "$stack" '
    .stacks[]? |
    select((.id // "") == $stack) |
    if (.vault.mount? and .vault.path?) then
      ((.vault.mount | sub("/+$"; "")) + "/data/" + (.vault.path | sub("^/+"; "")))
    else empty end,
    (.vault.paths[]? // empty),
    (.vault.kv_paths[]? // empty)
  ' "$STACKS_FILE" 2>/dev/null | awk 'NF && !seen[$0]++ {print}' | sort
}

contract_template_secret_paths() {
  local root="$1"
  [[ -d "$root/vault/templates" ]] || return 0

  grep -RhoE 'secret[[:space:]]+"[^"]+"' "$root/vault/templates" 2>/dev/null \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | awk 'NF && !seen[$0]++ {print}' \
    | sort
}

contract_template_referenced_keys() {
  local root="$1"
  [[ -d "$root/vault/templates" ]] || return 0

  {
    grep -RhoE '\.Data\.data\.[A-Za-z0-9_/-]+' "$root/vault/templates" 2>/dev/null \
      | sed -E 's/.*\.Data\.data\.//' || true
    grep -RhoE 'index[[:space:]]+\.Data\.data[[:space:]]+"[^"]+"' "$root/vault/templates" 2>/dev/null \
      | sed -E 's/.*"([^"]+)".*/\1/' || true
  } | sed -E 's/[^A-Za-z0-9_/-].*$//' \
    | awk 'NF && !seen[$0]++ {print}' \
    | sort
}

contract_candidate_kv_paths() {
  local stack="$1" root="$2"

  {
    contract_registry_kv_paths "$stack"
    contract_template_secret_paths "$root"
    printf 'kv/data/%s\n' "$stack"
  } | awk 'NF && !seen[$0]++ {print}' | sort
}

contract_split_kv_path() {
  local raw="$1" p mount secret
  p="${raw#/}"

  if [[ "$p" =~ ^([^/]+)/data/(.+)$ ]]; then
    mount="${BASH_REMATCH[1]}"
    secret="${BASH_REMATCH[2]}"
  elif [[ "$p" =~ ^([^/]+)/(.+)$ ]]; then
    mount="${BASH_REMATCH[1]}"
    secret="${BASH_REMATCH[2]}"
  else
    mount="kv"
    secret="$p"
  fi

  mount="${mount%/}"
  secret="${secret#/}"
  printf '%s\t%s\n' "$mount" "$secret"
}

contract_actual_keys_for_path() {
  local kv_path="$1" mount secret json split
  split="$(contract_split_kv_path "$kv_path")"
  mount="${split%%$'\t'*}"
  secret="${split#*$'\t'}"

  [[ -n "$CURRENT_TOKEN" ]] || return 3
  json="$(read_kv_secret "$mount" "$secret" 2>/dev/null)" || return 1
  jq -r 'keys_unsorted[]?' <<< "$json" 2>/dev/null | sort
}

contract_print_list_or_none() {
  local label="$1" file="$2"
  printf '%s\n' "$label"
  if [[ -s "$file" ]]; then
    sed 's/^/  - /' "$file"
  else
    printf '  none\n'
  fi
}

contract_diff_report() {
  local expected_file="$1" actual_file="$2" missing_file unused_file
  missing_file="$(mk_tmp_file)"
  unused_file="$(mk_tmp_file)"

  comm -23 "$expected_file" "$actual_file" > "$missing_file" || true
  comm -13 "$expected_file" "$actual_file" > "$unused_file" || true

  contract_print_list_or_none "Missing expected/template keys" "$missing_file"
  printf '\n'
  contract_print_list_or_none "Actual keys not referenced by contract/templates" "$unused_file"
}

contract_vault_key_usage_report() {
  local stack="$1" root expected_file template_file registry_file path_file actual_file path rc split mount secret

  root="$(docker_stack_root "$stack")"
  expected_file="$(mk_tmp_file)"
  template_file="$(mk_tmp_file)"
  registry_file="$(mk_tmp_file)"
  path_file="$(mk_tmp_file)"

  contract_registry_expected_keys "$stack" > "$registry_file" || true
  contract_template_referenced_keys "$root" > "$template_file" || true
  cat "$registry_file" "$template_file" | awk 'NF && !seen[$0]++ {print}' | sort > "$expected_file"
  contract_candidate_kv_paths "$stack" "$root" > "$path_file"

  cat <<EOF
Read-only Vault contract and key usage audit
============================================

Stack: $stack
Root:  $root

Purpose
-------
This report compares the stack's expected Vault keys against the keys that are
actually present in Vault. It does not write to Vault, Docker, files, or Compose.

Important caveat
----------------
"Unused" means not referenced by stacks.json or vault/templates/*.ctmpl that this
operator can inspect. The application may still read that key directly, so treat
unused findings as review items, not deletion instructions.

Contract sources
----------------
  stacks.json expected keys:       $(wc -l < "$registry_file" | tr -d ' ') key(s)
  vault/templates referenced keys: $(wc -l < "$template_file" | tr -d ' ') key(s)
  candidate Vault secret paths:    $(wc -l < "$path_file" | tr -d ' ') path(s)

EOF

  contract_print_list_or_none "Registry expected keys" "$registry_file"
  printf '\n'
  contract_print_list_or_none "Template-referenced keys" "$template_file"
  printf '\n'
  contract_print_list_or_none "Candidate Vault secret paths" "$path_file"
  printf '\n'

  if [[ ! -s "$expected_file" ]]; then
    cat <<EOF
No expected keys were inferred.

Recommended next step
---------------------
Add stack-specific expected_keys to config/stacks.json or make sure the stack's
vault/templates/*.ctmpl files are present under the stack root.

EOF
  fi

  if [[ -z "$CURRENT_TOKEN" ]]; then
    cat <<EOF
Vault read status
-----------------
No active operator session token is loaded, so actual KV keys were not read.
Start a session from the main menu, then rerun this audit for missing/unused key
comparison.

EOF
    return 0
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    actual_file="$(mk_tmp_file)"
    split="$(contract_split_kv_path "$path")"
    mount="${split%%$'\t'*}"
    secret="${split#*$'\t'}"

    printf 'Vault path: %s\n' "$path"
    printf '  Mount:  %s\n' "$mount"
    printf '  Secret: %s\n\n' "$secret"

    rc=0
    contract_actual_keys_for_path "$path" > "$actual_file" || rc=$?
    if [[ "$rc" == "0" ]]; then
      contract_print_list_or_none "Actual keys present" "$actual_file"
      printf '\n'
      if [[ -s "$expected_file" ]]; then
        contract_diff_report "$expected_file" "$actual_file"
      else
        printf 'No expected key list available, so missing/unused comparison was skipped.\n'
      fi
    elif [[ "$rc" == "3" ]]; then
      printf 'Skipped. No active operator session token.\n'
    else
      printf 'Unable to read this Vault path with the active token.\n'
      printf 'This may be normal if the path is only a candidate or the token lacks access.\n'
    fi
    printf '\n%s\n\n' '------------------------------------------------------------'
  done < "$path_file"
}

contract_vault_key_usage_flow() {
  local stack
  stack="$(docker_select_stack)" || return 0
  action_log "contract.vault-key-usage stack=$stack"
  ui_textbox "Vault contract audit: $stack" "$(contract_vault_key_usage_report "$stack")" || true
}

docker_stack_status_summary() {
  local stack="$1" total=0 running=0 agent_count=0 agent_fail=0 sidecar_count=0 rendered_total=0 cname role state health files

  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    total=$((total + 1))
    state="$(docker_state "$cname")"
    health="$(docker_health "$cname")"
    [[ "$state" == "running" ]] && running=$((running + 1))
    role="$(docker_container_role "$cname")"
    case "$role" in
      vault-agent)
        agent_count=$((agent_count + 1))
        [[ "$(docker_status_word "$state" "$health")" == "FAIL" ]] && agent_fail=$((agent_fail + 1))
        files="$(docker_dir_file_count "$cname" /vault/secrets)"
        rendered_total=$((rendered_total + files))
        ;;
      tailscale)
        sidecar_count=$((sidecar_count + 1))
        ;;
    esac
  done < <(docker_stack_container_names "$stack")

  local agent_status secrets_status network_status stack_status
  if (( agent_count == 0 )); then
    agent_status="none"
  elif (( agent_fail > 0 )); then
    agent_status="FAIL"
  else
    agent_status="OK"
  fi

  if (( agent_count == 0 )); then
    secrets_status="n/a"
  elif (( rendered_total > 0 )); then
    secrets_status="OK"
  else
    secrets_status="WARN"
  fi

  (( sidecar_count > 0 )) && network_status="sidecar" || network_status="native"

  if (( total == 0 )); then
    stack_status="missing"
  elif (( running < total || agent_fail > 0 )); then
    stack_status="WARN"
  else
    stack_status="OK"
  fi

  printf '%s|%s|%s|%s|%s|%s|%s' "$stack_status" "$running" "$total" "$agent_status" "$secrets_status" "$network_status" "$rendered_total"
}

docker_stack_overview_report() {
  local stack summary status running total agent_status secrets_status network_status rendered

  cat <<EOF
Prime01 Docker/Vault stack overview
===================================

Goal
----
This mode checks whether each stack has a coherent Vault Agent relationship:
containers are up, auth files are mounted, rendered secrets exist, and apps can
see the expected runtime secret paths. It does not print secret values.

$(printf '%-20s %-8s %-12s %-12s %-10s %-10s %-9s\n' 'Stack' 'Status' 'Containers' 'VaultAgent' 'Secrets' 'Network' 'Rendered')
$(printf '%-20s %-8s %-12s %-12s %-10s %-10s %-9s\n' '-----' '------' '----------' '----------' '-------' '-------' '--------')
EOF

  while IFS= read -r stack; do
    [[ -n "$stack" ]] || continue
    summary="$(docker_stack_status_summary "$stack")"
    IFS='|' read -r status running total agent_status secrets_status network_status rendered <<< "$summary"
    printf '%-20s %-8s %-12s %-12s %-10s %-10s %-9s\n' \
      "$(docker_clip "$stack" 20)" \
      "$status" \
      "${running}/${total}" \
      "$agent_status" \
      "$secrets_status" \
      "$network_status" \
      "$rendered"
  done < <(docker_stack_names)

  cat <<EOF

Legend
------
OK       healthy enough for this check
WARN     something is missing, starting, or only partially standard
FAIL     stopped/unhealthy or unable to verify a required relationship
none     no Vault Agent detected, possibly normal for infrastructure stacks

Next step
---------
Pick "Inspect stack" for an aligned, scrollable report with containers, mounts,
Vault Agent auth file checks, rendered secret file listings, and app visibility.
EOF
}

docker_stack_detail_report() {
  local stack="$1" root cname service role state health image user any_agent=0

  root="$(docker_stack_root "$stack")"

  cat <<EOF
Prime01 stack diagnostic report
===============================

Stack: $stack
Root:  $root

Container summary
-----------------
$(printf '  %-34s %-14s %-16s %-10s %-10s %-15s %s\n' 'Container' 'Role' 'Service' 'State' 'Health' 'User' 'Image')
$(printf '  %-34s %-14s %-16s %-10s %-10s %-15s %s\n' '---------' '----' '-------' '-----' '------' '----' '-----')
EOF

  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    service="$(docker_service "$cname")"
    role="$(docker_container_role "$cname")"
    state="$(docker_state "$cname")"
    health="$(docker_health "$cname")"
    image="$(docker_image "$cname")"
    user="$(docker_user "$cname")"
    printf '  %-34s %-14s %-16s %-10s %-10s %-15s %s\n' \
      "$(docker_clip "$cname" 34)" \
      "$(docker_clip "$role" 14)" \
      "$(docker_clip "$service" 16)" \
      "$state" \
      "$health" \
      "$(docker_clip "$user" 15)" \
      "$(docker_clip "$image" 44)"
  done < <(docker_stack_container_names "$stack")

  cat <<EOF

Prime01 setup integrity checks
------------------------------
  Root exists:              $([[ -d "$root" ]] && echo OK || echo WARN) $root
  docker-compose.yml:       $([[ -f "$root/docker-compose.yml" ]] && echo OK || echo WARN) $root/docker-compose.yml
  runtime/vault-auth:       $([[ -d "$root/runtime/vault-auth" ]] && echo OK || echo WARN) $root/runtime/vault-auth
  runtime/secrets:          $([[ -d "$root/runtime/secrets" ]] && echo OK || echo WARN) $root/runtime/secrets
  vault/agent.hcl:          $([[ -f "$root/vault/agent.hcl" ]] && echo OK || echo WARN) $root/vault/agent.hcl
  vault/templates:          $([[ -d "$root/vault/templates" ]] && echo OK || echo WARN) $root/vault/templates

Vault Agent relationship
------------------------
EOF

  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    any_agent=1
    printf '%s\n\n' "$(docker_vault_agent_report "$cname")"
  done < <(docker_stack_vault_agents "$stack")

  if [[ "$any_agent" == "0" ]]; then
    cat <<EOF
  No Vault Agent container was detected for this stack.
  This may be normal for Vault itself or for stacks not using Vault Agent.

EOF
  fi

  docker_app_secret_visibility_report "$stack"
}

docker_select_stack() {
  local stack summary status running total agent_status secrets_status network_status rendered choice count=0

  menu_reset
  while IFS= read -r stack; do
    [[ -n "$stack" ]] || continue
    summary="$(docker_stack_status_summary "$stack")"
    IFS='|' read -r status running total agent_status secrets_status network_status rendered <<< "$summary"
    menu_add "$stack" "${status} | containers ${running}/${total} | agent ${agent_status} | secrets ${secrets_status}"
    count=$((count + 1))
  done < <(docker_stack_names)

  if (( count == 0 )); then
    ui_msg "Docker" "No Compose-labelled stacks were found. Use container/path inspection, or add the stack to stacks.json later."
    return 1
  fi

  menu_add "manual" "Enter a Compose project / stack id manually"
  menu_add "back" "Back"
  choice="$(menu_choose "Prime01 stack" "Choose a stack to inspect. Details open as aligned reports, not menu text.")" || return 1

  case "$choice" in
    manual)
      ui_input "Stack id" "Compose project / stack id" "$STACK_NAME"
      ;;
    back)
      return 1
      ;;
    *)
      printf '%s' "$choice"
      ;;
  esac
}

docker_select_container() {
  local line name role service state health choice stack="${1:-}"
  local -a names=()

  if [[ -n "$stack" ]]; then
    mapfile -t names < <(docker_stack_container_names "$stack")
  else
    mapfile -t names < <(docker_names)
  fi

  [[ "${#names[@]}" -gt 0 ]] || { ui_msg "Docker" "No running containers found."; return 1; }

  menu_reset
  for name in "${names[@]}"; do
    role="$(docker_container_role "$name")"
    service="$(docker_service "$name")"
    state="$(docker_state "$name")"
    health="$(docker_health "$name")"
    menu_add "$name" "${role} | service ${service} | ${state}/${health}"
  done
  menu_add "manual" "Enter a container name manually"
  menu_add "back" "Back"

  choice="$(menu_choose "Docker container" "Choose a container. Detailed output opens in a scrollable report.")" || return 1
  case "$choice" in
    manual)
      ui_input "Docker container" "Container name" "p1-vault-vault"
      ;;
    back)
      return 1
      ;;
    *)
      printf '%s' "$choice"
      ;;
  esac
}

docker_container_detail_report() {
  local cname="$1" state health service project role image user workdir
  state="$(docker_state "$cname")"
  health="$(docker_health "$cname")"
  service="$(docker_service "$cname")"
  project="$(docker_project "$cname")"
  role="$(docker_container_role "$cname")"
  image="$(docker_image "$cname")"
  user="$(docker_user "$cname")"
  workdir="$(docker_working_dir "$cname")"

  cat <<EOF
Container diagnostic report
===========================

Container: $cname
Project:   $project
Service:   $service
Role:      $role
Image:     $image
User:      $user
State:     $state
Health:    $health
Root:      ${workdir:-unknown}

Mounts
------
$(docker_mounts_table "$cname")

Common Prime01 path checks
--------------------------
$(docker_path_status_line "$cname" '/vault/auth' /vault/auth dir)
$(docker_path_status_line "$cname" '/vault/config' /vault/config dir)
$(docker_path_status_line "$cname" '/vault/secrets' /vault/secrets dir)
$(docker_path_status_line "$cname" '/run/stack-secrets' /run/stack-secrets dir)
$(docker_path_status_line "$cname" '/run/secrets' /run/secrets dir)

Suspicious path drift
---------------------
$(docker_mounts_legacy_warnings "$cname" || true)

Recent logs, redacted
---------------------
$(docker_run logs --tail 80 "$cname" 2>&1 | docker_redact_output || true)
EOF
}

docker_inspect_container_path() {
  local stack="${1:-}" cname cpath report exists_rc
  cname="$(docker_select_container "$stack")" || return 0
  cpath="$(ui_input "Container path" "Path to inspect inside ${cname}" "/run/stack-secrets")" || return 0
  [[ -n "$cpath" ]] || return 0

  action_log "docker.path.inspect container=$cname path=$cpath"
  exists_rc=0
  docker_exec_test "$cname" -e "$cpath" || exists_rc=$?

  report="Container path inspection
=========================

Container: $cname
Path:      $cpath
Exists:    $([[ "$exists_rc" == "0" ]] && echo yes || echo no)

Path metadata
-------------
$(docker_exec_stat_line "$cname" "$cpath")

Directory contents, max depth 3, names and metadata only
--------------------------------------------------------
$(docker_dir_listing_report "$cname" "$cpath" 3)
"

  ui_textbox "Docker path inspection" "$report" || true
}

docker_recent_logs_flow() {
  local stack cname report
  stack="$(docker_select_stack)" || return 0
  cname="$(docker_select_container "$stack")" || return 0
  action_log "docker.logs container=$cname"
  report="Recent logs, redacted
=====================

Container: $cname

$(docker_run logs --tail 160 "$cname" 2>&1 | docker_redact_output || true)
"
  ui_textbox "Docker logs" "$report" || true
}

docker_stack_detail_flow() {
  local stack
  stack="$(docker_select_stack)" || return 0
  action_log "docker.stack.inspect stack=$stack"
  ui_textbox "Stack diagnostic: $stack" "$(docker_stack_detail_report "$stack")" || true
}

docker_vault_agent_relationship_flow() {
  local stack cname count=0
  stack="$(docker_select_stack)" || return 0

  menu_reset
  while IFS= read -r cname; do
    [[ -n "$cname" ]] || continue
    menu_add "$cname" "$(docker_state "$cname")/$(docker_health "$cname") | rendered $(docker_dir_file_count "$cname" /vault/secrets) file(s)"
    count=$((count + 1))
  done < <(docker_stack_vault_agents "$stack")

  if (( count == 0 )); then
    ui_msg "Vault Agent" "No Vault Agent container was detected for stack: $stack"
    return 0
  fi

  menu_add "back" "Back"
  cname="$(menu_choose "Vault Agent" "Choose a Vault Agent container to inspect.")" || return 0
  [[ "$cname" == "back" ]] && return 0

  action_log "docker.vault-agent.inspect stack=$stack container=$cname"
  ui_textbox "Vault Agent: $cname" "$(docker_vault_agent_report "$cname")" || true
}

docker_container_detail_flow() {
  local stack cname
  stack="$(docker_select_stack)" || return 0
  cname="$(docker_select_container "$stack")" || return 0
  action_log "docker.container.inspect container=$cname"
  ui_textbox "Container: $cname" "$(docker_container_detail_report "$cname")" || true
}

docker_aware_doctor_flow() {
  trace_log "start"
  action_log "docker.doctor.open"
  local choice stack

  docker_require_available || return 0

  while true; do
    menu_reset
    menu_add "overview" "Read-only stack health overview focused on Vault Agent relationships"
    menu_add "stack" "Inspect one stack: containers, mounts, auth files, rendered files"
    menu_add "agent" "Inspect Vault Agent auth/render relationship for one stack"
    menu_add "visibility" "Check whether app containers can see rendered secret paths"
    menu_add "contract" "Audit expected/template Vault keys against actual KV keys"
    menu_add "container" "Inspect one container with aligned mount/path/log report"
    menu_add "path" "Inspect one path inside a selected container"
    menu_add "logs" "View recent redacted logs for a selected container"
    menu_add "back" "Back"

    choice="$(menu_choose "Stack / Vault Agent Doctor" "Read-only diagnostics only. Menus stay short; details open as aligned scrollable reports.")" || return 0
    case "$choice" in
      overview)
        action_log "docker.stack.overview"
        ui_textbox "Prime01 stack overview" "$(docker_stack_overview_report)" || true
        ;;
      stack)
        docker_stack_detail_flow
        ;;
      agent)
        docker_vault_agent_relationship_flow
        ;;
      visibility)
        stack="$(docker_select_stack)" || continue
        action_log "docker.secret-visibility stack=$stack"
        ui_textbox "Secret visibility: $stack" "$(docker_app_secret_visibility_report "$stack")" || true
        ;;
      contract)
        contract_vault_key_usage_flow
        ;;
      container)
        docker_container_detail_flow
        ;;
      path)
        stack="$(docker_select_stack)" || continue
        docker_inspect_container_path "$stack"
        ;;
      logs)
        docker_recent_logs_flow
        ;;
      back)
        return 0
        ;;
    esac
  done
}

# =============================================================================
# Operator settings
# =============================================================================

operator_settings_menu() {
  trace_log "start"
  action_log "Open operator settings"
  local choice summary val

  while true; do
    summary="Redaction: $(redaction_level_label)\nNamespace: $(vault_namespace_display)\nSession TTL: ${SESSION_TTL}\nToken drop: ${TOKEN_RUNTIME_DIR}\nTemp workspace: ${TMP_PARENT}"

    menu_reset
    menu_add "redaction" "Change KV value display redaction"
    menu_add "namespace" "Enable/disable Vault namespace and saved value"
    menu_add "session-ttl" "Change default short-lived session TTL"
    menu_add "token-dir" "Change temporary token drop directory"
    menu_add "tmpfs" "Change tmpfs workspace path"
    menu_add "integrity" "Refresh integrity manifest for current script/settings/stacks"
    menu_add "back" "Back to main menu"

    choice="$(menu_choose "Operator settings" "$summary\n\nChoose a setting")" || return 0

    case "$choice" in
      redaction)
        select_redaction_level || true
        ;;
      namespace)
        if ui_yesno "Vault namespace" "Does this Vault use Vault Enterprise namespaces?

Choose No for normal/community Vault. This writes vault_namespace_enabled=false to settings." "$(vault_namespace_is_enabled && echo yes || echo no)"; then
          val="$(ui_input "Vault namespace" "Vault namespace. Leave blank to disable namespace support." "${VAULT_NAMESPACE:-}")" || continue
          VAULT_NAMESPACE="$val"
          if [[ -n "$VAULT_NAMESPACE" ]]; then
            VAULT_NAMESPACE_ENABLED="true"
          else
            VAULT_NAMESPACE_ENABLED="false"
          fi
        else
          VAULT_NAMESPACE=""
          VAULT_NAMESPACE_ENABLED="false"
        fi
        save_settings
        ui_msg "Saved" "Vault namespace is now: $(vault_namespace_display)"
        ;;
      session-ttl)
        val="$(choose_duration "Session TTL" "$SESSION_TTL")" || continue
        SESSION_TTL="$val"
        save_settings
        ;;
      token-dir)
        val="$(ui_input "Token drop directory" "Where should temporary token files be written by default?" "$TOKEN_RUNTIME_DIR")" || continue
        [[ -n "$val" ]] || { ui_msg "Invalid" "Token directory cannot be empty."; continue; }
        TOKEN_RUNTIME_DIR="$val"
        save_settings
        ;;
      tmpfs)
        val="$(ui_input "Temporary workspace" "Tmpfs/ramfs path for secret-bearing temp files" "$TMP_PARENT")" || continue
        [[ -n "$val" ]] || { ui_msg "Invalid" "Temporary workspace cannot be empty."; continue; }
        TMP_PARENT="$val"
        save_settings
        ui_msg "Saved" "The new temp workspace will be used on the next run. Current workspace remains:\n\n$TMP_DIR"
        ;;
      integrity)
        refresh_integrity_manifest
        ui_msg "Integrity refreshed" "Updated:\n\n$INTEGRITY_FILE"
        ;;
      back)
        return 0
        ;;
    esac
  done
}

# =============================================================================
# CLI argument handling and routing
# =============================================================================

validate_run_mode() {
  case "$1" in
    menu|configure|settings|session|kv|approle|tokens|docker) return 0 ;;
    *) return 1 ;;
  esac
}

validate_redaction_level() {
  case "$1" in
    full|partial|values) return 0 ;;
    none|show|unredacted) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_redaction_level() {
  case "$1" in
    none|show|unredacted) printf 'values' ;;
    *) printf '%s' "$1" ;;
  esac
}

need_arg_value() {
  local opt="$1" val="${2:-}"
  [[ -n "$val" ]] || die "$opt requires a value"
}

parse_args() {
  trace_log "start"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --mode)
        need_arg_value "$1" "${2:-}"
        validate_run_mode "$2" || die "Invalid --mode: $2"
        RUN_MODE="$2"
        shift 2
        ;;
      --no-connect-prompt|--skip-connect-prompt)
        NO_CONNECTION_PROMPT=1
        shift
        ;;
      --vault-addr)
        need_arg_value "$1" "${2:-}"
        CLI_VAULT_ADDR="$2"
        shift 2
        ;;
      --vault-cacert)
        need_arg_value "$1" "${2:-}"
        CLI_VAULT_CACERT="$2"
        shift 2
        ;;
      --vault-namespace)
        need_arg_value "$1" "${2:-}"
        CLI_VAULT_NAMESPACE="$2"
        CLI_VAULT_NAMESPACE_ENABLED="true"
        shift 2
        ;;
      --no-vault-namespace)
        CLI_VAULT_NAMESPACE=""
        CLI_VAULT_NAMESPACE_ENABLED="false"
        shift
        ;;
      --vault-skip-verify)
        need_arg_value "$1" "${2:-}"
        normalize_bool "$2" && CLI_VAULT_SKIP_VERIFY="true" || CLI_VAULT_SKIP_VERIFY="false"
        shift 2
        ;;
      --vault-token-file)
        need_arg_value "$1" "${2:-}"
        CLI_VAULT_TOKEN_FILE="$2"
        shift 2
        ;;
      --session-ttl)
        need_arg_value "$1" "${2:-}"
        CLI_SESSION_TTL="$2"
        shift 2
        ;;
      --redaction)
        need_arg_value "$1" "${2:-}"
        validate_redaction_level "$2" || die "Invalid --redaction: $2"
        CLI_REDACTION_LEVEL="$(normalize_redaction_level "$2")"
        shift 2
        ;;
      --token-output-dir)
        need_arg_value "$1" "${2:-}"
        CLI_TOKEN_OUTPUT_DIR="$2"
        shift 2
        ;;
      --tmp-parent)
        need_arg_value "$1" "${2:-}"
        CLI_TMP_PARENT="$2"
        shift 2
        ;;
      --trace)
        OPERATOR_TRACE=1
        shift
        ;;
      --no-trace)
        OPERATOR_TRACE=0
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Unknown option: $1. Run $SCRIPT_BASENAME --help for supported flags."
        ;;
    esac
  done

  [[ $# -eq 0 ]] || die "Unexpected positional arguments: $*"
}

apply_cli_overrides() {
  trace_log "start"

  [[ -n "$CLI_VAULT_ADDR" ]] && VAULT_ADDR="$CLI_VAULT_ADDR"
  [[ -n "$CLI_VAULT_CACERT" ]] && VAULT_CACERT="$CLI_VAULT_CACERT"
  [[ "$CLI_VAULT_NAMESPACE" != "__unset__" ]] && VAULT_NAMESPACE="$CLI_VAULT_NAMESPACE"
  if [[ "$CLI_VAULT_NAMESPACE_ENABLED" != "__unset__" ]]; then
    VAULT_NAMESPACE_ENABLED="$CLI_VAULT_NAMESPACE_ENABLED"
    save_namespace_setting
  fi
  [[ -n "$CLI_VAULT_SKIP_VERIFY" ]] && VAULT_SKIP_VERIFY="$CLI_VAULT_SKIP_VERIFY"
  [[ -n "$CLI_VAULT_TOKEN_FILE" ]] && VAULT_TOKEN_FILE="$CLI_VAULT_TOKEN_FILE"
  [[ -n "$CLI_SESSION_TTL" ]] && SESSION_TTL="$CLI_SESSION_TTL"
  [[ -n "$CLI_REDACTION_LEVEL" ]] && REDACTION_LEVEL="$CLI_REDACTION_LEVEL"
  [[ -n "$CLI_TOKEN_OUTPUT_DIR" ]] && TOKEN_RUNTIME_DIR="$CLI_TOKEN_OUTPUT_DIR"
  [[ -n "$CLI_TMP_PARENT" ]] && TMP_PARENT="$CLI_TMP_PARENT"

  case "$REDACTION_LEVEL" in
    full|partial|values) ;;
    none|show|unredacted) REDACTION_LEVEL="values" ;;
    *) die "Invalid redaction level after applying overrides: $REDACTION_LEVEL" ;;
  esac
}

check_vault_connection_status() {
  trace_log "start"
  action_log "Check Vault seal status"
  local seal_json sealed

  if seal_json="$(vault_api_noauth GET sys/seal-status 2>/dev/null)"; then
    sealed="$(jq -r '.sealed // empty' <<< "$seal_json")"
    if [[ "$sealed" == "true" ]]; then
      warn "Vault is reachable but sealed: $VAULT_ADDR"
    fi
  else
    warn "Could not query Vault seal status at $VAULT_ADDR"
  fi
}

prepare_vault_connection() {
  trace_log "start"
  if [[ "$NO_CONNECTION_PROMPT" == "1" ]]; then
    action_log "Use Vault connection from settings/env/flags"
    [[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is unset. Provide --vault-addr, env, or saved settings."
    check_vault_connection_status
  else
    configure_vault_connection
  fi
}

route_mode() {
  trace_log "$RUN_MODE"
  case "$RUN_MODE" in
    menu)
      main_menu
      ;;
    configure)
      configure_vault_connection
      ;;
    settings)
      operator_settings_menu
      ;;
    session)
      mint_session_token
      ;;
    kv)
      [[ -n "$CURRENT_TOKEN" ]] || mint_session_token
      kv_edit_flow
      ;;
    approle)
      [[ -n "$CURRENT_TOKEN" ]] || mint_session_token
      approle_render_flow
      ;;
    tokens)
      token_helper_menu
      ;;
    docker)
      docker_aware_doctor_flow
      ;;
  esac
}

# =============================================================================
# Main menu
# =============================================================================

main_menu() {
  trace_log "start"
  local choice session_status summary
  while true; do
    if [[ -n "$CURRENT_TOKEN" ]]; then session_status="active"; else session_status="none"; fi
    summary="Session: $session_status\nVault: ${VAULT_ADDR}\nNamespace: $(vault_namespace_display)\nCA cert: ${VAULT_CACERT:-none}\nRedaction: $(redaction_level_label)"

    menu_reset
    menu_add "configure" "Configure Vault address, CA cert, namespace"
    menu_add "settings" "Operator settings, including redaction level"
    menu_add "session" "Start/restart short-lived in-memory session"
    menu_add "kv" "Browse and edit KV secrets"
    menu_add "approle" "Render AppRole auth files"
    menu_add "tokens" "Mint child/operator/factory/delegated tokens"
    menu_add "docker" "Read-only Stack / Vault Agent Doctor"
    menu_add "exit" "Exit"
    choice="$(menu_choose "Prime01 Vault Operator" "$summary\n\nChoose an action")" || return 0

    case "$choice" in
      configure) configure_vault_connection ;;
      settings) operator_settings_menu ;;
      session)
        if [[ -n "$SESSION_TOKEN" ]]; then
          ui_yesno "Restart session" "A session already exists. Revoke it and start a new one?" "no" || continue
          revoke_session_token || true
          CURRENT_TOKEN=""
        fi
        mint_session_token
        ;;
      kv) kv_edit_flow ;;
      approle) approle_render_flow ;;
      tokens) token_helper_menu ;;
      docker) docker_aware_doctor_flow ;;
      exit) return 0 ;;
      *) ui_msg "Invalid" "Unknown menu choice: $choice" ;;
    esac
  done
}

usage() {
  cat <<USAGE
Usage: $SCRIPT_BASENAME [options]

Workflow flags:
  -h, --help
      Show this help and exit.

  --mode menu|configure|settings|session|kv|approle|tokens|docker
      Start directly in a workflow. Default: menu. Docker mode is the read-only Stack / Vault Agent Doctor. It focuses on Vault Agent/auth/rendered-secret relationships and can audit expected/template Vault keys against actual KV keys. It is not a generic Docker explorer.

  --no-connect-prompt
      Skip the initial Vault connection TUI. Use saved settings, env, and
      CLI overrides. This is useful for automation/Codex-driven runs.

Vault connection flags:
  --vault-addr URL
  --vault-cacert PATH
  --vault-namespace NAME
  --no-vault-namespace
      Explicitly remember/use no Vault namespace. This writes
      vault_namespace_enabled=false to settings when saved.

  --vault-skip-verify true|false
  --vault-token-file PATH

Operator behavior flags:
  --session-ttl TTL
      Examples: 15m, 2h, 24h.

  --redaction full|partial|values
      Controls KV value display for this run.

  --token-output-dir PATH
      Default: <operator-config-dir>/token-drop.

  --tmp-parent PATH
      Must be tmpfs/ramfs. Default: /dev/shm/prime01-vault-operator.

Logging flags:
  --trace
  --no-trace

Environment overrides still supported:
  OPERATOR_CONFIG_DIR=/path/to/config
  VAULT_ADDR or VAULT_API_ADDR or MAIN_VAULT_ADDR
  VAULT_CACERT or VAULT_API_CACERT or HOST_VAULT_CA_CERT
  VAULT_NAMESPACE
  VAULT_SKIP_VERIFY=true|false
  VAULT_TOKEN_FILE=/root/.vault-token
  TOKEN_RUNTIME_DIR=/path/to/token-drop
  TMP_PARENT=/dev/shm/prime01-vault-operator
  REDACTION_LEVEL=full|partial|values
  OPERATOR_TRACE=1

Examples:
  $SCRIPT_BASENAME --mode kv --no-connect-prompt --redaction values
  $SCRIPT_BASENAME --mode tokens --vault-token-file /root/.vault-token --no-connect-prompt
  $SCRIPT_BASENAME --mode docker --no-connect-prompt
USAGE
}

main() {
  parse_args "$@"

  trace_log "start"
  action_log "Launch Prime01 Vault Operator"

  need_cmd curl
  need_cmd jq
  need_cmd mktemp

  ensure_config
  load_settings
  apply_cli_overrides
  init_tmp_dir

  case "$RUN_MODE" in
    settings|docker)
      action_log "Skip Vault connection preflight for ${RUN_MODE} mode"
      ;;
    *)
      prepare_vault_connection
      ;;
  esac

  route_mode
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
