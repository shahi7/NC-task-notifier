#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <ssh-target> <remote-dir>"
  echo "Example: $0 ubuntu@my-server /home/ubuntu/nc-discord"
  exit 1
fi

SSH_TARGET="$1"
REMOTE_DIR="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Syncing project to ${SSH_TARGET}:${REMOTE_DIR}"
ssh "$SSH_TARGET" "mkdir -p '$REMOTE_DIR'"

rsync -az --delete \
  --exclude '.git/' \
  --exclude '.venv/' \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude '.DS_Store' \
  --exclude '.env' \
  --exclude 'data/' \
  --exclude 'queue/' \
  --exclude 'task_state.json' \
  --exclude 'calendar_sync_token.txt' \
  "$REPO_ROOT/" "${SSH_TARGET}:${REMOTE_DIR}/"

echo "==> Ensuring runtime directories exist on remote host"
ssh "$SSH_TARGET" "
  mkdir -p '$REMOTE_DIR/data/queue/pending' \
           '$REMOTE_DIR/data/queue/processing' \
           '$REMOTE_DIR/data/queue/done' \
           '$REMOTE_DIR/data/queue/failed'
"

echo "==> Deploying stack"
ssh "$SSH_TARGET" "
  cd '$REMOTE_DIR' &&
  docker compose pull || true &&
  docker compose up -d --build
"

echo "==> Done"
echo "Remote logs:"
echo "  ssh $SSH_TARGET 'cd $REMOTE_DIR && docker compose logs -f --tail=100 bot poller'"