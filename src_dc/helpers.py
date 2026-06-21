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

SIGNAL_URL = os.getenv("SIGNAL_URL")
SIGNAL_SENDER = os.getenv("SIGNAL_SENDER")
USER_MAP_SIGNAL = json.loads(os.getenv("USER_MAP_SIGNAL", "{}"))
DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

print("2a: CACHE_FILE =", CACHE_FILE)

# PARSING 

def parse_nc_datetime(value):
    print("7: parse_nc_datetime called with =", value)
    if not value:
        print("7a: no datetime value")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        print("7b: parsed datetime =", parsed.isoformat())
        return parsed
    except Exception as e:
        print("7c: failed to parse datetime ->", e)
        return None


def format_notification_text(subject: str, message: str, task_key: str) -> str:
    deadline, calendar, descr = "", "", ""
    subject = subject.split("(")[0]

    for line in message.splitlines():
        line = line.strip()
        if line.startswith("Calendar:"):
            calendar = line.replace("Calendar: ", "").strip().lower()
        elif line.startswith("Date:"):
            date_value = line.replace("Date:", "").strip()
            if " - " in date_value:
                date_value = date_value.split(" - ")[0].strip()
            deadline = date_value
        elif line.startswith("Description:"):
            descr = line

    parts = [subject]
    if descr:
        parts.append(descr)
    if deadline:
        parts.append(f"Deadline: {deadline}")
    if calendar:
        state = load_state()
        if task_key not in state:
            state[task_key] = {}
        state[task_key].update({
            "calendar_name": calendar.lower(),
            "workflow_status": "new",
        })
        save_state(state)

    return "\n".join(parts)

def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


# CACHE: avoid duplicate notif send

def cleanup_old_cache_files():
    print("3: entering cleanup_old_cache_files")
    cutoff = datetime.now(timezone.utc) - timedelta(days=CACHE_KEEP_DAYS)
    print("3a: cleanup cutoff =", cutoff.isoformat())
    for path in CACHE_DIR.glob("sent_notifications_*.json"):
        try:
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
            print("3b: checking cache file =", path, "mtime =", mtime.isoformat())
            if mtime < cutoff:
                print("3c: deleting old cache file =", path)
                path.unlink()
        except Exception as e:
            print("3d: cleanup error for", path, "->", e)
            pass
    print("4: finished cleanup_old_cache_files")

def load_cache():
    print("5: entering load_cache")
    if not CACHE_FILE.exists():
        print("5a: cache file does not exist")
        return set()
    try:
        data = set(json.loads(CACHE_FILE.read_text()))
        print("5b: loaded cache ids count =", len(data))
        return data
    except Exception as e:
        print("5c: failed to load cache ->", e)
        return set()


def save_cache(ids):
    print("6: entering save_cache")
    print("6a: saving ids count =", len(ids))
    CACHE_FILE.write_text(json.dumps(sorted(ids), indent=2))
    print("6b: cache saved to", CACHE_FILE)


# LOCAL STATE: for notif metadata

def load_state():
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))


def notify_delegator(status: str, task_key: str):
    message, payload, subject = "", "", ""
    state = load_state()
    # fetch discord username of assignee
    r = requests.get(f"https://discord.com/api/v10/users/{state[task_key][discord_user_id]}",
                 headers={
                          "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
                          "User-Agent": "NCDiscordBot (https://github.com/shahi7/NC-task-notifier, v0.1)"
                })
    user = r.get("username")
    if status == "working":
        message = f"@{user} has accepted the following task:\n"
    subject = state[task_key]["text"].split("Deadline:")[0]

    payload = {
                "message": f"Task #: {task_key}\n{subject}" + message,
                "number": SIGNAL_SENDER,
                "recipients": [USER_MAP_SIGNAL["DELEGATOR"]],
    }
    print("9c: payload =", payload)
    requests.post(SIGNAL_URL, json=payload, timeout=20)    

    return