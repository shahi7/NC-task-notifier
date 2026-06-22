"""
Parsing, local cache, and local metadata helper functions
"""

import json
from datetime import datetime, timezone, timedelta
import os
from pathlib import Path
import requests # type: ignore

STATE_FILE = Path("task_state.json")
CACHE_KEEP_DAYS = 3
CACHE_DIR = Path(".")
TODAY = datetime.now(timezone.utc).date().isoformat()
CACHE_FILE = CACHE_DIR / f"sent_notifications_{TODAY}.json"


def parse_nc_datetime(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def format_notification_text(subject: str, message: str, task_key: str) -> str:
    deadline, calendar, descr = "", "", ""
    subject = subject.split("(")[0].strip()

    for line in message.splitlines():
        line = line.strip()
        if line.startswith("Calendar:"):
            calendar = line.replace("Calendar:", "").strip().lower()
        elif line.startswith("Date:"):
            date_value = line.replace("Date:", "").strip()
            if " - " in date_value:
                date_value = date_value.split(" - ")[0].strip()
            deadline = date_value
        elif line.startswith("Description:"):
            descr = line.replace("Description:", "").strip()

    parts = [subject]
    if descr:
        parts.append(f"Description: {descr}")
    if deadline:
        parts.append(f"Deadline: {deadline}")

    state = load_state()
    task_key = str(task_key)
    if task_key not in state:
        state[task_key] = {}
    if calendar:
        state[task_key]["calendar_name"] = calendar
    state[task_key].setdefault("status", "pending")
    save_state(state)

    return "\n".join(parts)


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def cleanup_old_cache_files():
    cutoff = datetime.now(timezone.utc) - timedelta(days=CACHE_KEEP_DAYS)
    for path in CACHE_DIR.glob("sent_notifications_*.json"):
        try:
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
            if mtime < cutoff:
                path.unlink()
        except Exception:
            pass


def load_cache():
    if not CACHE_FILE.exists():
        return set()
    try:
        return set(json.loads(CACHE_FILE.read_text()))
    except Exception:
        return set()


def save_cache(ids):
    CACHE_FILE.write_text(json.dumps(sorted(str(x) for x in ids), indent=2))


def load_state():
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    normalized = {str(k): v for k, v in state.items()}
    STATE_FILE.write_text(json.dumps(normalized, indent=2))


def notify_delegator(button: str, task_key: str):
    message, payload, subject = "", "", ""
    state = load_state()
    # fetch discord username of assignee
    DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
    discord_user_id = str(state[task_key]["discord_user_id"])
    r = requests.get(f"https://discord.com/api/v10/users/{discord_user_id}",
                 headers={
                          "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
                          "User-Agent": "NCDiscordBot (https://github.com/shahi7/NC-task-notifier, v0.1)"
                })
    user = r.json().get("username")
    
    # cancel accept
    if button == "working" and state[task_key]["status"] == "pending":
        message = f"@{user} has cancelled this task:\n"
    # accept
    elif button == "working":
        message = f"@{user} has accepted the following task:\n"
    # cancel done
    elif button == "done" and state[task_key]["status"] == "pending":
        message = f"@{user} has updated this task to In-Progress:\n" 
    # done 
    elif button == "done":
        message = f"@{user} has completed the following task:\n"
       
    subject = state[task_key]["text"].split("Deadline:")[0]

    SIGNAL_URL = os.getenv("SIGNAL_URL")
    SIGNAL_SENDER = os.getenv("SIGNAL_SENDER")
    USER_MAP_SIGNAL = json.loads(os.getenv("USER_MAP_SIGNAL", "{}"))
    payload = {
                "message": message + f"Task #: {task_key}\n{subject}",
                "number": SIGNAL_SENDER,
                "recipients": [USER_MAP_SIGNAL["DELEGATOR"]],
    }
    print("9c: payload =", payload)
    requests.post(SIGNAL_URL, json=payload, timeout=20)    

    return