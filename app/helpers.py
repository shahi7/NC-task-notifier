"""
Parsing, local cache, and local metadata helper functions
"""

from datetime import datetime, timezone, timedelta
import os
from pathlib import Path
import json
from caldav import DAVClient  # type: ignore
import requests  # type: ignore
from dotenv import load_dotenv  # type: ignore

load_dotenv(Path(__file__).resolve().parent / ".env")

DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
STATE_FILE = DATA_DIR / "task_state.json"
CACHE_DIR = DATA_DIR

CACHE_KEEP_DAYS = 3
TODAY = datetime.now(timezone.utc).date().isoformat()
CACHE_FILE = CACHE_DIR / f"sent_notifications_{TODAY}.json"

REMINDER_HOURS_BEFORE = int(os.getenv("REMINDER_HOURS_BEFORE", "24"))
REMINDER_DAYS_BEFORE = int(os.getenv("REMINDER_DAYS_BEFORE", "0"))
REMINDER_DELTAS = json.loads(os.getenv("REMINDER_DELTAS", "[]"))


def get_secret(name: str, default: str | None = None) -> str | None:
    # local testing without vault

    # if secret stored in vault with _FILE pattern
    file_path = os.getenv(f"{name}_FILE", "").strip()
    if file_path:
        p = Path(file_path)
        if p.exists():
            return p.read_text(encoding="utf-8").strip()

    # otherwise, non-secret value stored in .env file
    value = os.getenv(name)
    if value is not None:
        return value

    return default

    # prod vers; with vault
    # file_var = os.getenv(f"{name}_FILE")
    # if file_var:
    #     return Path(file_var).read_text(encoding="utf-8").strip()
    # value = os.getenv(name)
    # if value is not None:
    #     return value
    # return default


NEXTCLOUD_USER = get_secret("NEXTCLOUD_USER")
NEXTCLOUD_PASS = get_secret("NEXTCLOUD_PASS")
NEXTCLOUD_BASE_URL = os.getenv("NEXTCLOUD_BASE_URL")


def parse_nc_datetime(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def format_text_and_state(
    subject: str, message: str, task_key: str, object_id, object_type
) -> str:
    deadline, calendar, descr = "", "", ""
    subject = subject.split("(")[0].strip()

    for line in message.splitlines():
        line = line.strip()
        if line.startswith("Calendar:"):
            calendar = line.replace("Calendar:", "").strip().lower()
        elif line.startswith("Date:"):
            date_value = line.replace("Date:", "").strip()
            if " " in date_value:
                date_value = date_value.split(" ")[0].strip()
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


def notify_delegator(task_key: str, action: bool = False, deadline: bool = False):
    message, payload, subject = "", "", ""
    state = load_state()

    update = ""
    # status update
    if action:
        update += f"Status: {state[task_key]['status']}\n"
    # deadline update
    if deadline:
        update += f"Deadline: {state[task_key]['deadline'].split('T')[0]}\n"

    message = "The following task has been updated:\n" + update
    subject = state[task_key]["subject"]
    USER_MAP_SIGNAL = json.loads(get_secret("USER_MAP_SIGNAL", "{}") or "{}")

    delegator_signal_key = str(state[task_key].get("delegator_signal_key", "")).strip()
    recipients = USER_MAP_SIGNAL.get(delegator_signal_key, [])

    SIGNAL_URL = os.getenv("SIGNAL_URL")
    SIGNAL_SENDER = get_secret("SIGNAL_SENDER")

    if not SIGNAL_URL or not SIGNAL_SENDER or not recipients:
        print("notify_delegator: missing signal config or recipients for", task_key)
        return

    payload = {
        "message": message + f"Task #: {task_key}\n{subject}",
        "number": SIGNAL_SENDER,
        "recipients": recipients,
    }
    # fix 2026-07-27: this printed recipient phone numbers into the logs
    print("9c: notifying delegator for task", task_key)
    requests.post(SIGNAL_URL, json=payload, timeout=20)


def get_client():
    # fix 2026-07-27: this printed the nextcloud app password into the logs
    print("caldav base url:", NEXTCLOUD_BASE_URL)
    try:
        client = DAVClient(  # pylint: disable=not-callable
            url=NEXTCLOUD_BASE_URL + "/remote.php/dav",
            username=NEXTCLOUD_USER,
            password=NEXTCLOUD_PASS,
        )
        # use the Vault/Nextcloud CA for this session client
        session.verify = "/etc/ssl/vault-ca.crt"
        return client
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

    # fix 2026-07-27: these were relative, so they missed /app/data/queue
    queue_dirs = [
        DATA_DIR / "queue" / "pending",
        DATA_DIR / "queue" / "processing",
        DATA_DIR / "queue" / "done",
        DATA_DIR / "queue" / "failed",
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
    state[task_key] = task
    save_state(state)
    return task["completed_timestamp"]


def completed(task_key, delta):
    state = load_state()
    task = state.get(task_key)
    cutoff = datetime.now(timezone.utc) - timedelta(days=delta)

    ts = task.get("completed_timestamp", "")
    if ts and datetime.fromisoformat(ts) < cutoff:
        return True
    return False


def normalize_status(status) -> str:
    s = str(status or "").strip().upper()
    if s in ("NEEDS-ACTION", "PENDING", "", "pending"):
        return "pending"
    if s in ("IN-PROCESS", "WORKING", "working"):
        return "working"
    if s in ("COMPLETED", "DONE", "done"):
        return "done"
    if s in ("CANCELLED", "CANCELED", "cancelled"):
        return "cancelled"
    return "pending"


def build_task_text(task: dict) -> str:
    subject = str(task.get("subject", "")).strip() or "Nextcloud Task"
    description = str(task.get("description", "")).strip()
    location = str(task.get("location", "")).strip()
    deadline = str(task.get("deadline", "")).split("T")[0]

    parts = [subject]
    if description:
        parts.append(f"Description: {description}")
    if location:
        parts.append(f"Location: {location}")
    if deadline:
        parts.append(f"Deadline: {deadline}")
    return "\n".join(parts)


def parse_deadline_value(value):
    if value is None:
        return None

    if isinstance(value, datetime):
        dt = value
    else:
        text = str(value).strip()
        if not text:
            return None
        try:
            dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except Exception:
            return None

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)

    return dt


def get_reminder_deltas():
    if REMINDER_DELTAS:
        return [timedelta(days=d, hours=h) for d, h in REMINDER_DELTAS]
    return [timedelta(days=REMINDER_DAYS_BEFORE, hours=REMINDER_HOURS_BEFORE)]


def normalize_deadline(value):
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.date().isoformat()
    return str(value).strip().split("T")[0]


# add multiple deltas to sent_deltas; for when task is due soon after creation, to avoid spam
def mark_due_reminder_deltas(
    task: dict, now: datetime, reminder_deltas: list[timedelta]
):
    deadline = parse_deadline_value(task.get("deadline"))
    if not deadline:
        return

    sent = set(task.get("sent_reminder_deltas", []))

    for delta in sorted(reminder_deltas, reverse=True):
        if delta < timedelta(0):
            continue
        if now >= deadline - delta:
            sent.add(str(delta))

    task["sent_reminder_deltas"] = sorted(sent)
