#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIGNAL_DATA_DIR="${SCRIPT_DIR}/signal-data"
mkdir -p "$SIGNAL_DATA_DIR"

if ! docker ps -a --format '{{.Names}}' | grep -wq "signal-api"; then
  docker run -d \
    --name signal-api \
    --restart unless-stopped \
    -p 8080:8080 \
    -v "$SIGNAL_DATA_DIR:/home/.local/share/signal-cli" \
    -e MODE=native \
    bbernhard/signal-cli-rest-api
else
  docker start signal-api >/dev/null || true
fi

python3 -m venv .venv
source .venv/bin/activate

python3 -m pip install --upgrade pip
python3 -m pip install discord.py python-dotenv requests icalendar caldav

echo "Setup complete."
echo "Working directory: $SCRIPT_DIR"
echo "Run with:"
echo "  cd \"$SCRIPT_DIR\""
echo "  source .venv/bin/activate"
echo "  source .env"
echo "  python3 src/discord-script.py"
