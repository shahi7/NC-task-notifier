"""
Parsing, local cache, and local metadata helper functions
"""


import json
import caldav # type: ignore
from datetime import datetime, timezone, timedelta
import os
from pathlib import Path
import requests # type: ignore
from dotenv import load_dotenv # type: ignore


load_dotenv(Path(__file__).resolve().parent.parent / ".env")


STATE_FILE = Path("task_state.json")
CACHE_KEEP_DAYS = 3
CACHE_DIR = Path(".")
TODAY = datetime.now(timezone.utc).date().isoformat()
CACHE_FILE = CACHE_DIR / f"sent_notifications_{TODAY}.json"


NEXTCLOUD_USER = os.getenv("NEXTCLOUD_USER")
NEXTCLOUD_PASS = os.getenv("NEXTCLOUD_PASS")
NEXTCLOUD_BASE_URL = os.getenv("NEXTCLOUD_BASE_URL")


def parse_nc_datetime(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def format_text_and_state(subject: str, message: str, task_key: str, object_id, object_type) -> str:
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
    state[task_key]["object_id"] = object_id
    state[task_key]["object_type"] = object_type
    state[task_key]["deadline"] = deadline
    state[task_key]["subject"] = subject
    state[task_key]["description"] = descr
    state[task_key]["notification_id"] = str(task_key)


    save_state(state)


    print("12x: object_type =", object_type)
    print("12y: object_id =", object_id)
    print("12z: calendar_name =", calendar)


    return "\n".join(parts)


# prefers event_uid as more stable key
def merge_task_into_event_uid(old_task_key: str, event_uid: str):
    state = load_state()
    old_task_key = str(old_task_key)
    event_uid = str(event_uid).strip()

    if not event_uid:
        print("16m: merge skipped, missing event_uid")
        return old_task_key

    old_task = state.get(old_task_key, {})
    existing_task = state.get(event_uid, {})

    print("16n: merging old_task_key =", old_task_key, "into event_uid =", event_uid)

    merged = dict(existing_task)
    merged.update(old_task)

    merged["event_uid"] = event_uid
    merged.setdefault("previous_message_ids", [])

    # old message_id; only newest notification will render buttons
    if existing_task.get("discord_message_id") and existing_task.get("discord_message_id") != merged.get("discord_message_id"):
        merged["previous_message_ids"].append(existing_task["discord_message_id"])

    state[event_uid] = merged

    if old_task_key != event_uid:
        state.pop(old_task_key, None)

    save_state(state)
    return event_uid


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


# TODO: debug
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


def get_client():
    try:
        return caldav.DAVClient(
            url=NEXTCLOUD_BASE_URL + "/remote.php/dav",
            username=NEXTCLOUD_USER,
            password=NEXTCLOUD_PASS,
        ) 
    except Exception as e:
        print(repr(e))


# use cron to run monthly
# important to keep local dataset small; event_uid/task lookups expensive (linear)
def cleanup_old_tasks_and_queue_files(days: int = 30):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    print("17: cleanup cutoff =", cutoff.isoformat())

    state = load_state()
    kept = {}
    removed_keys = []

    for task_key, task in state.items():
        if not isinstance(task, dict):
            removed_keys.append(task_key)
            continue

        ts = (
            task.get("workflow_updated_at")
            or task.get("discord_sent_at")
            or task.get("notification_datetime")
        )

        dt = parse_nc_datetime(ts) if ts else None
        if dt and dt < cutoff:
            removed_keys.append(task_key)
            continue

        kept[task_key] = task

    if removed_keys:
        print("17a: removing old task keys =", removed_keys)
    save_state(kept)

    queue_dirs = [
        Path("queue/pending"),
        Path("queue/processing"),
        Path("queue/done"),
        Path("queue/failed"),
    ]

    for qdir in queue_dirs:
        if not qdir.exists():
            continue
        for path in qdir.glob("*.json"):
            try:
                mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
                if mtime < cutoff:
                    print("17b: deleting old queue file =", str(path))
                    path.unlink()
            except Exception as e:
                print("17x: cleanup failed for", str(path), repr(e))


def completed_timestamp(task_key, action):
      state = load_state()
      task = state.get(task_key)

      if action == "done":
            task["completed_timestamp"] = utc_now_iso()
      else:
            task["completed_timestamp"] = ""
      return task["completed_timestamp"]


def completed(task_key, delta):
    state = load_state()
    task = state.get(task_key)
    cutoff = datetime.now(timezone.utc) - timedelta(days=delta)

    if task.get("completed_timestamp", "") and task["completed_timestamp"] < cutoff:
        return True
    return False