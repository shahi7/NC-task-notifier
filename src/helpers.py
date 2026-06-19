import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

STATE_FILE = Path("task_state.json")
CACHE_KEEP_DAYS = 3
CACHE_DIR = Path(".")
TODAY = datetime.now(timezone.utc).date().isoformat()
CACHE_FILE = CACHE_DIR / f"sent_notifications_{TODAY}.json"

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
    

def format_notification_text(subject: str, message: str) -> str:
    deadline = ""
    subject = subject.split("(")[0]

    for line in message.splitlines():
        line = line.strip()
        if line.startswith("Date:"):
            date_value = line.replace("Date:", "").strip()
            if " - " in date_value:
                date_value = date_value.split(" - ")[0].strip()
            deadline = date_value

    parts = [subject]
    if deadline:
        parts.append(f"Deadline: {deadline}")

    return "\n".join(parts)

def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


# CACHE

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


# LOCAL STATE

def load_state():
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))