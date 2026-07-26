#!/usr/bin/env bash
set -Eeuo pipefail

# validate the image lock and, when requested, the exact rendered Compose image set

: "${APPROVED_IMAGE_REGISTRY:?APPROVED_IMAGE_REGISTRY is required}"

usage() {
  cat <<'EOF'
Usage: verify-approved-images.sh LOCK_FILE [ENV_FILE [COMPOSE_FILE]]

LOCK_FILE contains one approved image per non-comment line. If ENV_FILE is
provided, the effective Compose image set must exactly match the lock.
EOF
}

lock_file="${1:-}"
env_file="${2:-}"
compose_file="${3:-docker-compose.yml}"

[[ -n "$lock_file" ]] || {
  usage >&2
  exit 2
}

[[ -f "$lock_file" && ! -L "$lock_file" ]] || {
  echo "approved-image lock must be a regular, non-symlink file" >&2
  exit 2
}

if [[ -n "$env_file" ]]; then
  [[ -f "$env_file" && ! -L "$env_file" ]] || {
    echo "approved-image verification requires a regular env file" >&2
    exit 2
  }
  [[ -f "$compose_file" && ! -L "$compose_file" ]] || {
    echo "approved-image verification requires a regular Compose file" >&2
    exit 2
  }
fi

approved_prefix="${APPROVED_IMAGE_REGISTRY%/}"
[[ -n "$approved_prefix" ]] || {
  echo "APPROVED_IMAGE_REGISTRY must not be empty" >&2
  exit 2
}

declare -A expected=()
declare -A rendered_set=()

validate_image() {
  local image="$1" remainder
  [[ "$image" == "${approved_prefix}/"* ]] || return 1
  remainder="${image#"${approved_prefix}/"}"
  [[ "$remainder" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]
}

line_no=0
while IFS= read -r image || [[ -n "$image" ]]; do
  line_no=$((line_no + 1))
  image="${image%$'\r'}"
  [[ -z "$image" || "$image" == \#* ]] && continue
  validate_image "$image" || {
    echo "invalid approved image reference at lock line ${line_no}" >&2
    exit 1
  }
  [[ -z "${expected[$image]+x}" ]] || {
    echo "duplicate approved image reference at lock line ${line_no}" >&2
    exit 1
  }
  expected["$image"]=1
done < "$lock_file"

[[ "${#expected[@]}" -gt 0 ]] || {
  echo "approved-image lock contains no images" >&2
  exit 1
}

[[ -n "$env_file" ]] || {
  echo "approved-image lock validation passed"
  exit 0
}

rendered="$(docker compose --env-file "$env_file" -f "$compose_file" config --images)" || {
  echo "unable to render Compose image set" >&2
  exit 1
}

while IFS= read -r image || [[ -n "$image" ]]; do
  image="${image%$'\r'}"
  [[ -n "$image" ]] || continue
  validate_image "$image" || {
    echo "rendered Compose contains an image outside the approved lock policy" >&2
    exit 1
  }
  rendered_set["$image"]=1
done <<< "$rendered"

[[ "${#rendered_set[@]}" -gt 0 ]] || {
  echo "rendered Compose image set is empty" >&2
  exit 1
}

if [[ "${#expected[@]}" -ne "${#rendered_set[@]}" ]]; then
  echo "rendered Compose image set does not match the approved lock" >&2
  exit 1
fi

for image in "${!expected[@]}"; do
  [[ -n "${rendered_set[$image]+x}" ]] || {
    echo "rendered Compose image set does not match the approved lock" >&2
    exit 1
  }
done

echo "approved-image lock and rendered Compose image set match"
