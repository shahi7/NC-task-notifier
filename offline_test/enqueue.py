#!/usr/bin/env python3
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

from helpers import load_state, save_state

QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)

discord_user_id = int(input("Discord user ID: ").strip())
task_key = input("Task key [test-1]: ").strip() or "test-1"

text = """Offline test task
Description: test Discord buttons and delegator Signal
Deadline: 2026-06-21
"""

state = load_state()
if task_key not in state:
    state[task_key] = {}
state[task_key]["workflow_status"] = "new"
state[task_key]["discord_user_id"] = discord_user_id
state[task_key]["text"] = text
save_state(state)

job = {
    "type": "send_task_dm",
    "discord_user_id": discord_user_id,
    "text": text,
    "task_key": task_key,
    "created_at": datetime.now(timezone.utc).isoformat(),
}

tmp_path = QUEUE_DIR / f"{uuid.uuid4()}.tmp"
final_path = QUEUE_DIR / f"{uuid.uuid4()}.json"
tmp_path.write_text(json.dumps(job, indent=2))
tmp_path.rename(final_path)

print(f"Queued {final_path}")