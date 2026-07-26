#!/usr/bin/env bash
set -Eeuo pipefail

# validate-structure.sh must accept a clean stack and reject tracked secrets, non-recursive gitignore, and committed .env

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
subject="$repo_root/scripts/validate-structure.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Build a minimal but structurally-valid stack in a throwaway git repo.
scaffold() {
  local root="$1"
  rm -rf -- "$root"
  mkdir -p "$root"/{runtime/secrets/app,runtime/vault-auth,vault/templates}
  : > "$root/docker-compose.yml"
  : > "$root/.env.example"
  : > "$root/vault/agent.hcl"
  for d in runtime/secrets runtime/secrets/app runtime/vault-auth; do
    : > "$root/$d/.gitkeep"
  done
  cat > "$root/.gitignore" <<'IGN'
.env
.env.*
!.env.example
runtime/secrets/**
!runtime/secrets/.gitkeep
!runtime/secrets/app/
!runtime/secrets/app/.gitkeep
runtime/vault-auth/*
!runtime/vault-auth/.gitkeep
IGN
  git -C "$root" init -q
  git -C "$root" add -A
  git -C "$root" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init
}

expect() { # <label> <expected-exit> <actual-exit>
  if [ "$2" -eq "$3" ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1 (expected exit $2, got $3)" >&2
    exit 1
  fi
}

root="$tmp/stack"

# 1. Clean stack passes.
scaffold "$root"
set +e; bash "$subject" --root "$root" >/dev/null 2>&1; rc=$?; set -e
expect "clean stack accepted" 0 "$rc"

# 2. A tracked secret under runtime/secrets is rejected.
scaffold "$root"
echo "supersecret" > "$root/runtime/secrets/app/rendered_token"
git -C "$root" add -f runtime/secrets/app/rendered_token
git -C "$root" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm leak
set +e; bash "$subject" --root "$root" >/dev/null 2>&1; rc=$?; set -e
expect "tracked secret rejected" 1 "$rc"

# 3. A non-recursive runtime/secrets pattern is rejected.
scaffold "$root"
printf 'runtime/secrets/*\n!runtime/secrets/.gitkeep\n' > "$root/.gitignore"
git -C "$root" add -A; git -C "$root" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm badignore
set +e; bash "$subject" --root "$root" >/dev/null 2>&1; rc=$?; set -e
expect "non-recursive gitignore rejected" 1 "$rc"

# 4. A committed real .env is rejected.
scaffold "$root"
echo "SECRET=1" > "$root/.env"
git -C "$root" add -f .env
git -C "$root" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm envleak
set +e; bash "$subject" --root "$root" >/dev/null 2>&1; rc=$?; set -e
expect "tracked .env rejected" 1 "$rc"

echo "All validate-structure tests passed."
