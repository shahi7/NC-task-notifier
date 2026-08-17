#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
subject="$repo_root/scripts/deploy-stack-over-ssh.sh"

output="$({
  STACK_NAME=example \
  DEPLOY_TARGET=p1 \
  DEPLOY_STACK_PATH=/home/common/stacks/example \
  bash "$subject" --resolve-context
})"

expected_keys='STACK_NAME DEPLOY_TARGET DEPLOY_HOST DEPLOY_USER DEPLOY_SSH_KEY_VAR DEPLOY_STACK_PATH'
actual_keys="$(printf '%s\n' "$output" | sed 's/=.*//' | paste -sd ' ' -)"
[[ "$actual_keys" == "$expected_keys" ]]

if DEPLOY_TARGET=p1 DEPLOY_STACK_PATH=/home/common/other/example \
  bash "$subject" --resolve-context >/dev/null 2>&1; then
  echo "path outside the approved root must fail" >&2
  exit 1
fi

if STACK_NAME='bad name' DEPLOY_TARGET=p1 DEPLOY_STACK_PATH=/home/common/stacks/example \
  bash "$subject" --resolve-context >/dev/null 2>&1; then
  echo "unsafe stack names must fail" >&2
  exit 1
fi

echo "deploy context tests passed"
