#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
subject="$repo_root/scripts/remote-deploy-release.sh"
verifier="$repo_root/scripts/verify-approved-images.sh"
approved="registry.example.invalid/group/project/approved"
image="${approved}/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
install -d -m 700 "$tmp/bin" "$tmp/allowed" "$tmp/staging"

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"

if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi

if [[ "$*" == *" config --images"* ]]; then
  printf '%s\n' "$MOCK_IMAGE"
  exit 0
fi

if [[ "$*" == *" up -d "* && "${MOCK_DOCKER_MODE:-good}" == "fail-once" ]]; then
  count=0
  [[ -f "$MOCK_DOCKER_COUNT" ]] && count="$(<"$MOCK_DOCKER_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$MOCK_DOCKER_COUNT"
  [[ "$count" -gt 1 ]] || exit 42
fi

exit 0
MOCK
chmod 700 "$tmp/bin/docker"

make_fixture() {
  local name="$1"
  live="$tmp/allowed/$name"
  stage="$tmp/staging/$name-release0001"
  install -d -m 700 \
    "$live/runtime/vault-auth" \
    "$live/runtime/control" \
    "$live/scripts" \
    "$stage/ci" \
    "$stage/scripts"
  printf 'UNCHANGED=1\n' > "$live/.env"
  printf 'fake-role\n' > "$live/runtime/vault-auth/role_id"
  printf 'fake-secret\n' > "$live/runtime/vault-auth/secret_id"
  chmod 600 "$live/.env" "$live/runtime/vault-auth/role_id" "$live/runtime/vault-auth/secret_id"
  printf 'old-source\n' > "$live/old-marker"
  printf 'services: {}\n' > "$live/docker-compose.yml"

  printf 'services: {}\n' > "$stage/docker-compose.yml"
  printf '%s\n' "$image" > "$stage/ci/approved-images.lock"
  cat > "$stage/permissions.tsv" <<'PERMS'
# mode	 state	 type	 path	 note	 check
2750	present	dir	.	test root
600	present	file	.env	test env
640	present	file	docker-compose.yml	test compose
700	present	dir	runtime	test runtime
700	present	dir	runtime/vault-auth	test auth dir
400	present	file	runtime/vault-auth/role_id	test role
400	present	file	runtime/vault-auth/secret_id	test secret
2750	present	dir	scripts	test scripts
750	present	file	scripts/permissions.sh	test permissions
750	present	file	scripts/setup-service.sh	test setup
750	present	file	scripts/verify-approved-images.sh	test verifier
PERMS
  cp "$repo_root/scripts/permissions.sh" "$stage/scripts/permissions.sh"
  cp "$verifier" "$stage/scripts/verify-approved-images.sh"
  cat > "$stage/scripts/setup-service.sh" <<'SETUP'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == "--bootstrap-only" && "${2:-}" == "-y" ]]
SETUP
  chmod 700 \
    "$stage/scripts/permissions.sh" \
    "$stage/scripts/setup-service.sh" \
    "$stage/scripts/verify-approved-images.sh"
  printf 'new-source\n' > "$stage/new-marker"
}

run_subject() {
  PATH="$tmp/bin:$PATH" \
  MOCK_DOCKER_LOG="$tmp/docker.log" \
  MOCK_DOCKER_COUNT="$tmp/docker.count" \
  MOCK_IMAGE="$image" \
  APPROVED_IMAGE_REGISTRY="$approved" \
    bash "$subject" \
      "$live" "$stage" "$tmp/allowed" "$tmp/staging" release0001 \
      ci/approved-images.lock "$approved" 30 false false
}

make_fixture success
: > "$tmp/docker.log"
run_subject >/dev/null
[[ -f "$live/new-marker" && ! -e "$live/old-marker" ]]
[[ "$(<"$live/.env")" == "UNCHANGED=1" ]]
[[ "$(<"$live/runtime/vault-auth/secret_id")" == "fake-secret" ]]
[[ -f "$live/.deploy/current-release" ]]
if grep -q ' compose .* down' "$tmp/docker.log"; then
  echo "deployment must not use compose down" >&2
  exit 1
fi

rm -f "$tmp/docker.count"
make_fixture rollback
: > "$tmp/docker.log"
if MOCK_DOCKER_MODE=fail-once run_subject >/dev/null 2>&1; then
  echo "expected the first deployment health gate to fail" >&2
  exit 1
fi
[[ -f "$live/old-marker" && ! -e "$live/new-marker" ]]
[[ "$(<"$live/.env")" == "UNCHANGED=1" ]]
[[ "$(<"$live/runtime/vault-auth/secret_id")" == "fake-secret" ]]
if grep -q ' compose .* down' "$tmp/docker.log"; then
  echo "rollback path must not use compose down" >&2
  exit 1
fi

echo "remote-deploy-release tests passed"
