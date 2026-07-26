#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
stack_root="$repo_root"
manifest="${PERMISSIONS_MANIFEST:-${repo_root}/permissions.tsv}"
action=""
: "${STACK_WORKSPACE_GROUP:=workspace}"
workspace_gid="$(getent group "$STACK_WORKSPACE_GROUP" | awk -F: 'NR==1 {print $3}')"
[ -n "$workspace_gid" ] || { echo "Missing workspace group: $STACK_WORKSPACE_GROUP" >&2; exit 1; }
: "${CONTAINER_RUNTIME_UID:=65534}"
: "${CONTAINER_RUNTIME_GID:=65534}"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

usage() {
  cat <<EOF
Usage: ./scripts/permissions.sh <check|apply> [--root <dir>] [--manifest <file>]

check  Validate current mode bits against ${manifest##"${repo_root}"/} (read-only).
apply  Apply the manifest's expected mode bits.

Optional entries in the manifest are skipped when absent.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    check|apply) action="$1"; shift ;;
    --root) stack_root="${2:?missing value for --root}"; shift 2 ;;
    --manifest) manifest="${2:?missing value for --manifest}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$action" ] || { echo "Missing action: check or apply." >&2; usage >&2; exit 2; }

if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
  echo "Missing permissions manifest: $manifest" >&2
  exit 1
fi

valid_manifest_path() {
  local rel="$1"
  [ "$rel" = "." ] || [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ && "$rel" != /* && "$rel" != *..* && "$rel" != */./* ]]
}

target_path() {
  local rel="$1"
  if [ "$rel" = "." ]; then
    printf '%s' "$stack_root"
  else
    printf '%s/%s' "$stack_root" "$rel"
  fi
}

workspace_managed_path() {
  case "$1" in
    runtime|runtime/*|backups|backups/*|data/tailscale|data/tailscale/*) return 1 ;;
    *) return 0 ;;
  esac
}

container_owned_path() {
  case "$1" in
    runtime|runtime/*|data/tailscale|data/tailscale/*) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
checked=0
changed=0

# apply aborts on the first problem; check reports all and fails at the end
problem() {
  echo "$1" >&2
  if [ "$action" = "apply" ]; then
    exit 1
  fi
  fail=1
}

while IFS=$'\t' read -r mode state kind path note check || [ -n "${mode:-}" ]; do
  mode="$(trim "${mode:-}")"
  state="$(trim "${state:-}")"
  kind="$(trim "${kind:-}")"
  path="$(trim "${path:-}")"
  note="$(trim "${note:-}")"
  check="$(trim "${check:-}")"

  case "$mode" in
    ""|\#*|mode) continue ;;
  esac

  [ -n "${path:-}" ] || continue
  if ! valid_manifest_path "$path"; then
    problem "UNSAFE   path escapes stack root: ${path}"
    continue
  fi
  target="$(target_path "$path")"

  if [ -L "$target" ]; then
    problem "SYMLINK  expected real ${kind:-path} ${path}"
    continue
  fi

  if [ ! -e "$target" ]; then
    if [ "${state:-present}" = "optional" ]; then
      continue
    fi
    problem "MISSING  expected ${mode} ${kind:-file} ${path}"
    continue
  fi

  case "$kind" in
    file)
      if [ ! -f "$target" ]; then
        problem "TYPE     expected regular file ${path}"
        continue
      fi
      ;;
    dir)
      if [ ! -d "$target" ]; then
        problem "TYPE     expected directory ${path}"
        continue
      fi
      ;;
    *)
      problem "TYPE     unknown manifest type '${kind}' for ${path}"
      continue
      ;;
  esac

  if [ "$action" = "apply" ]; then
    # leading '=' makes special bits authoritative; plain numeric modes keep setgid
    chmod -- "=$mode" "$target"
    if workspace_managed_path "$path"; then
      chgrp -- "$workspace_gid" "$target"
    elif container_owned_path "$path"; then
      chown -- "$CONTAINER_RUNTIME_UID:$CONTAINER_RUNTIME_GID" "$target"
    fi
    changed=$((changed + 1))
    continue
  fi

  actual="$(stat -c '%a' "$target")"
  checked=$((checked + 1))
  if [ "$actual" != "$mode" ]; then
    problem "MISMATCH expected ${mode} got ${actual} ${kind:-file} ${path}${note:+  # ${note}}"
  fi

  if workspace_managed_path "$path"; then
    actual_gid="$(stat -c '%g' "$target")"
    [ "$actual_gid" = "$workspace_gid" ] || problem "GROUP    expected ${STACK_WORKSPACE_GROUP} for ${path}"
  elif container_owned_path "$path"; then
    actual_owner="$(stat -c '%u:%g' "$target")"
    [ "$actual_owner" = "$CONTAINER_RUNTIME_UID:$CONTAINER_RUNTIME_GID" ] || problem "OWNER    expected ${CONTAINER_RUNTIME_UID}:${CONTAINER_RUNTIME_GID} for ${path}"
  fi

  case "${check:-}" in
    "") ;;
    nonempty)
      if [ ! -s "$target" ]; then
        problem "EMPTY     expected non-empty ${kind:-file} ${path}${note:+  # ${note}}"
      fi
      ;;
    *)
      problem "Unknown check '${check}' for ${path}"
      ;;
  esac
done < "$manifest"

if [ "$action" = "apply" ]; then
  # Tailscale creates state files after bootstrap. Normalize ownership
  # recursively without changing their application-managed mode bits.
  if [ -d "$stack_root/data/tailscale" ]; then
    chown -R -- "$CONTAINER_RUNTIME_UID:$CONTAINER_RUNTIME_GID" "$stack_root/data/tailscale"
  fi
  echo "Applied permissions from manifest (${changed} paths updated) at ${stack_root}."
  exit 0
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Permissions match manifest (${checked} paths checked) at ${stack_root}."
