#!/usr/bin/env bash
set -Eeuo pipefail

# CI structure/secret-hygiene gate: needs only the working tree and git index, no secrets

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) repo_root="${2:?missing value for --root}"; shift 2 ;;
    -h|--help) echo "Usage: validate-structure.sh [--root <stack-dir>]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
cd "$repo_root"

fail=0
note() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# deliberately small universal minimum; the secret-hygiene checks are the real gate.
# runtime/* is a tmpfs mount recreated at deploy time, never git-tracked, so it's
# never present in a fresh checkout -- not required to exist here, only required
# (below) to be empty-or-absent from git and correctly gitignored if it does exist.
required_dirs=()
required_files=(
  docker-compose.yml .env.example .gitignore
)

# secret/state paths may hold only .gitkeep and must be recursively gitignored
secret_prefixes_required=(runtime/secrets runtime/vault-auth)
secret_prefixes_optional=(runtime/control data backups)

# Secret-bearing filename patterns that must never be tracked anywhere.
secret_name_globs=(
  '*.key' '*.pem' '*.p12' '*.pfx' 'id_rsa' 'id_rsa.*' 'id_ed25519'
  'role_id' 'secret_id' '*.tfstate' '*.tfstate.*' 'acme.json' '*_authkey'
)

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "FAIL  not a git repository; structure hygiene needs the git index" >&2
  exit 1
}

check_required() {
  local d f
  for d in "${required_dirs[@]}"; do
    [ -d "$d" ] || note "missing required directory: $d/"
  done
  for f in "${required_files[@]}"; do
    [ -f "$f" ] || note "missing required file: $f"
  done
}

# Only a .gitkeep may be tracked under a secret/state prefix.
check_tracked_under_prefix() {
  local prefix tracked
  for prefix in "$@"; do
    while IFS= read -r tracked; do
      [ -n "$tracked" ] || continue
      case "$(basename "$tracked")" in
        .gitkeep) ;;
        *) note "secret/state path is git-tracked: $tracked" ;;
      esac
    done < <(git ls-files -- "$prefix" 2>/dev/null)
  done
}

# nested probes catch non-recursive `dir/*` gitignore patterns
check_recursion() {
  local prefix probe
  for prefix in "$@"; do
    for probe in "$prefix/__probe_secret__" "$prefix/nested_stack/__probe_secret__"; do
      git check-ignore -q "$probe" || \
        note ".gitignore does not exclude $probe (use ${prefix}/** not ${prefix}/*)"
    done
  done
}

check_secret_names() {
  local glob tracked
  for glob in "${secret_name_globs[@]}"; do
    while IFS= read -r tracked; do
      [ -n "$tracked" ] || continue
      note "secret-named file is git-tracked: $tracked"
    done < <(git ls-files -- ":(glob)**/$glob" ":(glob)$glob" 2>/dev/null)
  done
  # Any .env except *.example must never be tracked.
  while IFS= read -r tracked; do
    [ -n "$tracked" ] || continue
    case "$tracked" in
      *.example) ;;
      *) note "environment file with real values is git-tracked: $tracked" ;;
    esac
  done < <(git ls-files -- ':(glob)**/.env' ':(glob).env' ':(glob)**/.env.*' ':(glob).env.*' 2>/dev/null)
}

check_required
check_tracked_under_prefix "${secret_prefixes_required[@]}" "${secret_prefixes_optional[@]}"
check_recursion "${secret_prefixes_required[@]}"
for p in "${secret_prefixes_optional[@]}"; do
  [ -d "$p" ] && check_recursion "$p"
done
check_secret_names

if [ "$fail" -ne 0 ]; then
  echo "Structure/secret-hygiene validation FAILED." >&2
  exit 1
fi
echo "Structure and secret-hygiene checks passed."
