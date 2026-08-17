#!/usr/bin/env bash
# Mint one Headscale pre-auth key and store it in the stack Vault KV record.
# The key is kept only in locked temporary files/shell memory and is never printed.
set -Eeuo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
: "${SERVICE_ENV:=${REPO_ROOT}/.env}"

load_env() {
  local line key value
  [ -f "$SERVICE_ENV" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# || "$line" != *=* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -v "$key" ]] && continue
    export "$key=$value"
  done < "$SERVICE_ENV"
}
load_env

: "${HEADSCALE_CONTAINER:=headscale}"
: "${HEADSCALE_USER:?HEADSCALE_USER must be the numeric Headscale service-user ID}"
: "${TS_AUTHKEY_EXPIRATION:=24h}"
: "${VAULT_TOKEN_FILE:?set VAULT_TOKEN_FILE to a privileged Vault token file}"
: "${VAULT_API_ADDR:=https://127.0.0.1:8200}"
: "${VAULT_API_CACERT:=/home/common/vault-v2/runtime/secrets/tls/ca.crt}"
: "${VAULT_KV_PATH:=kv/data/${STACK_NAME:?STACK_NAME must be set}}"

[[ "$HEADSCALE_USER" =~ ^[0-9]+$ ]] || { echo "HEADSCALE_USER must be numeric" >&2; exit 2; }

key_file="$(mktemp)"
payload_file="$(mktemp)"
cleanup() {
  unset vault_token key current
  rm -f -- "$key_file" "$payload_file"
}
trap cleanup EXIT INT TERM

# Headscale writes the newly created secret to stderr in human output mode.
docker exec "$HEADSCALE_CONTAINER" headscale --force preauthkeys create \
  --user "$HEADSCALE_USER" --expiration "$TS_AUTHKEY_EXPIRATION" --reusable \
  >"$key_file" 2>&1

key="$(grep -Eo '(hskey|tskey)-auth-[A-Za-z0-9_-]+' "$key_file" | head -n1 || true)"
[[ -n "$key" ]] || { echo "Headscale did not return a pre-auth key" >&2; exit 1; }

vault_token="$(tr -d '\r\n' < "$VAULT_TOKEN_FILE")"
current="$(curl -fsS --cacert "$VAULT_API_CACERT" -H "X-Vault-Token: $vault_token" "${VAULT_API_ADDR%/}/v1/${VAULT_KV_PATH}")"
printf '%s' "$current" | jq -c '.data.data // {}' \
  | jq --arg value "$key" '. + {tailscale_authkey:$value}' \
  | jq '{data:.}' >"$payload_file"
curl -fsS --cacert "$VAULT_API_CACERT" -H "X-Vault-Token: $vault_token" \
  -H 'Content-Type: application/json' -X POST --data-binary "@$payload_file" \
  "${VAULT_API_ADDR%/}/v1/${VAULT_KV_PATH}" >/dev/null

echo "Refreshed Headscale auth key in Vault without disclosure."
