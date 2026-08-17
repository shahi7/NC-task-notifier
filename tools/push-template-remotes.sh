#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: push-template-remotes.sh [prime1|zeppelin1|all] [branch]

Push the current branch from service-template-v2 to the configured GitLab
service-template remotes.

Remotes:
  prime1-template    https://gitlab.m.onsaa.org/servers/prime1/service-template-v2.git
  zeppelin1-template https://gitlab.m.onsaa.org/servers/zeppelin1/service-template-v2.git

Default target: all
Default branch: current checked out branch
EOF
}

target="${1:-all}"
branch="${2:-}"

if [[ "$target" == "-h" || "$target" == "--help" ]]; then
  usage
  exit 0
fi

cd "$repo_root"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ -z "$branch" ]; then
  branch="$current_branch"
fi

push_remote() {
  local remote="$1"
  echo "Pushing ${branch} -> ${remote}/${branch}" >&2
  git push "$remote" "${branch}:${branch}"
}

case "$target" in
  prime1)
    push_remote prime1-template
    ;;
  zeppelin1|z1)
    push_remote zeppelin1-template
    ;;
  all)
    push_remote prime1-template
    push_remote zeppelin1-template
    ;;
  *)
    echo "Unknown target: $target" >&2
    usage >&2
    exit 2
    ;;
esac
