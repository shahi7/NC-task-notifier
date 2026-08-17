#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
subject="$repo_root/scripts/verify-approved-images.sh"
approved="registry.example.invalid/group/project/approved"
image_a="${approved}/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image_b="${approved}/vault@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
install -d -m 700 "$tmp/bin"

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${MOCK_DOCKER_MODE:-good}" in
  good)
    printf '%s\n%s\n%s\n' "$MOCK_IMAGE_B" "$MOCK_IMAGE_A" "$MOCK_IMAGE_A"
    ;;
  missing)
    printf '%s\n' "$MOCK_IMAGE_A"
    ;;
  extra)
    printf '%s\n%s\n%s\n' "$MOCK_IMAGE_A" "$MOCK_IMAGE_B" "${MOCK_IMAGE_A/app/extra}"
    ;;
  fail)
    exit 42
    ;;
  *)
    exit 99
    ;;
esac
MOCK
chmod 700 "$tmp/bin/docker"

printf '%s\n%s\n' "$image_a" "$image_b" > "$tmp/good.lock"
printf 'EXAMPLE=1\n' > "$tmp/example.env"
printf 'services: {}\n' > "$tmp/compose.yml"

export APPROVED_IMAGE_REGISTRY="$approved"
export MOCK_IMAGE_A="$image_a"
export MOCK_IMAGE_B="$image_b"
export PATH="$tmp/bin:$PATH"

expect_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

bash "$subject" "$tmp/good.lock" >/dev/null
MOCK_DOCKER_MODE=good bash "$subject" "$tmp/good.lock" "$tmp/example.env" "$tmp/compose.yml" >/dev/null

printf '%s\n%s\n' "$image_a" "$image_a" > "$tmp/duplicate.lock"
expect_fail bash "$subject" "$tmp/duplicate.lock"

: > "$tmp/empty.lock"
expect_fail bash "$subject" "$tmp/empty.lock"

printf '%s\n' 'docker.io/library/alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$tmp/wrong-registry.lock"
expect_fail bash "$subject" "$tmp/wrong-registry.lock"

printf '%s\n' "${approved}/app@sha256:abc" > "$tmp/short.lock"
expect_fail bash "$subject" "$tmp/short.lock"

ln -s "$tmp/good.lock" "$tmp/link.lock"
expect_fail bash "$subject" "$tmp/link.lock"

MOCK_DOCKER_MODE=missing expect_fail bash "$subject" "$tmp/good.lock" "$tmp/example.env" "$tmp/compose.yml"
MOCK_DOCKER_MODE=extra expect_fail bash "$subject" "$tmp/good.lock" "$tmp/example.env" "$tmp/compose.yml"
MOCK_DOCKER_MODE=fail expect_fail bash "$subject" "$tmp/good.lock" "$tmp/example.env" "$tmp/compose.yml"

echo "verify-approved-images tests passed"
