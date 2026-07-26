#!/usr/bin/env sh
set -eu

ROLE_ID_FILE="/vault/auth/role_id"
SECRET_ID_FILE="/vault/auth/secret_id"
SOURCE_CONFIG="/vault/config/agent.hcl"
RENDERED_CONFIG="/tmp/vault-agent.hcl"

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_CACERT:=/vault/tls/ca.crt}"
: "${VAULT_NAMESPACE:=}"
: "${APPROLE_MOUNT:=approle}"
: "${VAULT_STATIC_SECRET_RENDER_INTERVAL:=5m}"

fail() {
  echo "$*" >&2
  exit 1
}

escape_sed_replacement() {
  # Escape characters that are meaningful in the sed replacement side.
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

validate_file_nonempty() {
  path="$1"
  label="$2"
  [ -f "$path" ] || fail "Missing ${label} at ${path}"
  [ -s "$path" ] || fail "Empty ${label} at ${path}"
}

case "$APPROLE_MOUNT" in
  *[!A-Za-z0-9_.-]*|'') fail "Invalid APPROLE_MOUNT: ${APPROLE_MOUNT}" ;;
esac

case "$VAULT_STATIC_SECRET_RENDER_INTERVAL" in
  ''|*[!0-9smhd]*) fail "Invalid VAULT_STATIC_SECRET_RENDER_INTERVAL: ${VAULT_STATIC_SECRET_RENDER_INTERVAL}" ;;
esac

validate_file_nonempty "$ROLE_ID_FILE" "Vault AppRole role_id"
validate_file_nonempty "$SECRET_ID_FILE" "Vault AppRole secret_id"
validate_file_nonempty "$SOURCE_CONFIG" "Vault Agent config template"

mkdir -p /tmp /vault/secrets/bot /vault/secrets/poller /vault/secrets/ts-sidecar /vault/secrets/vault-agent

addr="$(escape_sed_replacement "$VAULT_ADDR")"
cacert="$(escape_sed_replacement "$VAULT_CACERT")"
namespace="$(escape_sed_replacement "$VAULT_NAMESPACE")"
approle_mount="$(escape_sed_replacement "$APPROLE_MOUNT")"
render_interval="$(escape_sed_replacement "$VAULT_STATIC_SECRET_RENDER_INTERVAL")"

sed \
  -e "s|\$VAULT_ADDR|${addr}|g" \
  -e "s|\$VAULT_CACERT|${cacert}|g" \
  -e "s|\$VAULT_NAMESPACE|${namespace}|g" \
  -e "s|\$APPROLE_MOUNT|${approle_mount}|g" \
  -e "s|\$VAULT_STATIC_SECRET_RENDER_INTERVAL|${render_interval}|g" \
  "$SOURCE_CONFIG" > "$RENDERED_CONFIG"

chmod 0400 "$RENDERED_CONFIG"

# Vault Agent performs AppRole login, token renewal, and template rendering.
exec vault agent -config="$RENDERED_CONFIG"
