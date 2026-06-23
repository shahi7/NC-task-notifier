"""
Polls NextCloud calendar via CalDAV sync token for newly created/modified VTODOs
and queues Discord DMs for TaskBot
"""
# TODO: schedule in background (cron); cron should retry upon ConnectionError 
# TODO: notify delegator
# TODO: allow list of time deltas for notification 
#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
from caldav import get_calendar # type: ignore
import os
from pathlib import Path
import uuid
import json
from dotenv import load_dotenv # type: ignore
from helpers import (
    cleanup_old_cache_files,
    completed,
    get_client,
    load_state,
    save_state,
    merge_task_into_event_uid,
)

QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)
SYNC_TOKEN_FILE = Path("calendar_sync_token.txt")

print("1: script started")

# use env vars
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

REMINDER_HOURS_BEFORE = int(os.getenv("REMINDER_HOURS_BEFORE", "24"))
REMINDER_DAYS_BEFORE = int(os.getenv("REMINDER_DAYS_BEFORE", "0"))

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
USER_MAP_DC = json.loads(os.getenv("USER_MAP_DC", "{}"))
USER_MAP_SIGNAL = json.loads(os.getenv("USER_MAP_SIGNAL", "{}"))

CALENDAR_NAME = os.getenv("CALENDAR_NAME")
CALENDAR_URL = os.getenv("CALENDAR_URL")

print("2: config loaded")
print("2b: USER_MAP keys =", list(USER_MAP_DC.keys()))


def load_sync_token():
    if not SYNC_TOKEN_FILE.exists():
        return None
    return SYNC_TOKEN_FILE.read_text().strip() or None


def save_sync_token(token):
    if token:
        SYNC_TOKEN_FILE.write_text(token)


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


# checks if it is time to send a reminder
def should_send_reminder(task: dict, now: datetime, reminder_delta: timedelta):
    status = task.get("status", "pending")
    if status == "done":
        return False
    if task.get("new"):
        return True

    deadline = parse_deadline_value(task.get("deadline"))
    if not deadline:
        return False

    reminder_time = deadline - reminder_delta
    if now < reminder_time:
        return False
    # if now > deadline:
    #    return False

    last_sent = parse_deadline_value(task.get("last_deadline_reminder_sent_at"))
    if last_sent:
        return False

    return True


# handoff layer for persistent TaskBot
def enqueue_discord_dm(text: str, discord_user_id: int, task_key: str):
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


# TODO: change to TODO
def parse_vevent(vevent):
    print("vevent:\n", vevent)
    subject = getattr(vevent.summary, "value", "").strip() if getattr(vevent, "summary", None) else "Nextcloud event"
    location = getattr(vevent.location, "value", "") if getattr(vevent, "location", None) else ""
    description = getattr(vevent.description, "value", "").strip() if getattr(vevent, "description", None) else ""
    dtstart = getattr(vevent.dtstart, "value", None) if getattr(vevent, "dtstart", None) else None

    parts = [subject]
    if description:
        parts.append(f"Description: {description}")
    if location:
        parts.append(f"Location: {location}")
    if dtstart:
        parts.append(f"Deadline: {dtstart}")

    return "\n".join(parts), subject, description, dtstart


# store event info (importantly, event uid) once vtodo obtained
def store_event(task_key: str, calendar_name: str, event, vevent, text: str):
    state = load_state()
    task_key = str(task_key)

    if task_key not in state:
        state[task_key] = {}

    state[task_key]["calendar_name"] = (calendar_name or "").strip().lower()
    state[task_key]["status"] = state[task_key].get("status", "pending")
    state[task_key]["object_type"] = "caldav_event"
    state[task_key]["object_id"] = str(getattr(vevent.uid, "value", "") if getattr(vevent, "uid", None) else "")
    state[task_key]["event_uid"] = str(getattr(vevent.uid, "value", "") if getattr(vevent, "uid", None) else "")
    state[task_key]["event_url"] = str(getattr(event, "url", ""))
    state[task_key]["deadline"] = str(getattr(vevent.dtstart, "value", "") if getattr(vevent, "dtstart", None) else "") # .due
    state[task_key]["location"] = str(getattr(vevent.location, "value", "") if getattr(vevent, "location", None) else "")
    state[task_key]["subject"] = getattr(vevent.summary, "value", "").strip() if getattr(vevent, "summary", None) else ""
    state[task_key]["description"] = getattr(vevent.description, "value", "").strip() if getattr(vevent, "description", None) else ""
    state[task_key]["notification_id"] = task_key
    state[task_key]["text"] = text
    state[task_key]["notification_datetime"] = datetime.now(timezone.utc).isoformat()
    state[task_key]["new"] = True

    ids = []
    assignees = getattr(vevent, "attendee", None)
    if not isinstance(assignees, list): assignees = [assignees]
    for a in assignees:
        email = str(getattr(a, "value", "")).replace("mailto:", "")
        ids.append(USER_MAP_DC.get(email))
    state[task_key]["assignees"] = ids

    organizer = getattr(vevent, "organizer", None)
    state[task_key]["delegator"] = USER_MAP_SIGNAL.get(str(getattr(organizer, "value", "")).replace("mailto:", "")) \
        if organizer else ""

    save_state(state)

    print("12x: object_type =", state[task_key]["object_type"])
    print("12y: object_id =", state[task_key]["object_id"])
    print("12z: calendar_name =", state[task_key]["calendar_name"])


# searches through calendars
def sync_calendar_search():
    print("8: entering process_calendar_changes")
    old_token = load_sync_token()
    print("8a: old_token =", old_token)

    changed_items = []

    with get_client() as client:
        principal = client.principal()
        calendars = list(principal.calendars())
        print("8b: calendars found =", len(calendars))

        for calendar in calendars:
            calendar_name = (calendar.get_display_name() or "").strip().lower()
            print("8c: checking calendar =", calendar_name)

            if not old_token:
                print("8d: no old token yet, saving initial token and skipping initial send")
                changes = calendar.get_objects(load_objects=True)
                save_sync_token(getattr(changes, "sync_token", None))
                continue

            # get new event objects since last sync
            try:
                changes = calendar.get_objects(sync_token=old_token, load_objects=True, disable_fallback=True)
            except Exception as e:
                print("8x: get_objects failed for", calendar_name, repr(e))
                continue

            print("changes:\n", changes)

            # record new TODOs
            for event in changes:
                try:
                    vevent = event.vobject_instance.vevent
                    # vtodo = event.get_vobject_instance() # read-only
                except Exception as e:
                    print("8y: skipping non-vevent or bad vobject", repr(e))
                    continue

                print("event candidate:\n", event)

                uid = getattr(vevent.uid, "value", "") if getattr(vevent, "uid", None) else ""
                if not uid:
                    print("8z: skipping because missing uid")
                    continue

                changed_items.append((calendar_name, event, vevent))

            save_sync_token(getattr(changes, "sync_token", None))

    return changed_items


def sync_calendar():
    print("8: entering process_calendar_changes")

    changed_items = []
    changes = []

    print("before get_calendar", flush=True)
    with get_client() as client:
        calendar = client.calendar(url=CALENDAR_URL)
        print("after get_calendar", flush=True)
        print("calendar =", repr(calendar), flush=True)
        print("calendar is None =", calendar is None, flush=True)
        if calendar is not None:
            # initializing token
            old_token = load_sync_token()
            print("8a: old_token =", old_token)
            if not old_token:
                print("8d: no old token yet, saving initial token and skipping initial send")
                changes = calendar.get_objects(load_objects=True)
                print("initial sync_token =", repr(getattr(changes, "sync_token", None)), flush=True)
                save_sync_token(getattr(changes, "sync_token", None))
                old_token = load_sync_token()
                print("reloaded token =", repr(old_token), flush=True)

            # get new event objects since last sync
            try:
                print("before get_objects", flush=True)
                changes = calendar.get_objects(sync_token=old_token, load_objects=True, disable_fallback=True)
                print("after get_objects", flush=True)
            except Exception as e:
                print("8x: get_objects failed for", CALENDAR_NAME, repr(e))

            print("changes:\n", changes)

            # record new TODOs
            for event in changes:
                try:
                    vevent = event.vobject_instance.vevent
                    # vtodo = event.get_vobject_instance() # read-only
                except Exception as e:
                    print("8y: skipping non-vevent or bad vobject", repr(e))
                    continue

                print("event candidate:\n", event)

                uid = getattr(vevent.uid, "value", "") if getattr(vevent, "uid", None) else ""
                if not uid:
                    print("8z: skipping because missing uid")
                    continue

                changed_items.append((CALENDAR_NAME, event, vevent))

            save_sync_token(getattr(changes, "sync_token", None))

    return changed_items


def main():
    print("10: entering main")
    cleanup_old_cache_files()

    changed_items = sync_calendar()
    print("10b: changed_items =", len(changed_items))

    # first refresh/update local state from any synced calendar changes
    for calendar_name, event, vevent in changed_items:
        event_uid = getattr(vevent.uid, "value", "") if getattr(vevent, "uid", None) else ""
        print("11: raw event_uid =", event_uid)

        if not event_uid:
            print("11a: skipping because missing uid")
            continue

        text, subject, description, dtstart = parse_vevent(vevent)
        print("12a: subject =", subject)
        print("12b: description =", description)
        print("12c: dtstart =", dtstart)

        store_event(event_uid, calendar_name, event, vevent, text)
        
        final_task_key = merge_task_into_event_uid(str(event_uid), str(event_uid))
        print("12d: synced event into state =", final_task_key)

    # then scan all active tasks and send reminders if inside configured window
    reminder_delta = timedelta(days=REMINDER_DAYS_BEFORE, hours=REMINDER_HOURS_BEFORE)
    now = datetime.now(timezone.utc)
    print("13a: now =", now.isoformat())
    print("13b: reminder_delta =", reminder_delta)

    state = load_state()

    new_state = {}
    for task_key, task in state.items():
        if not isinstance(task, dict):
            continue

        # delete stale completed tasks
        if completed(task_key, 1):
            print("deleting stale task: ", task_key)
            continue 
        new_state[task_key] = task

        print("13c: checking task_key =", task_key)

        if not should_send_reminder(task, now, reminder_delta):
            print("13d: reminder not due for", task_key)
            continue
        task["new"] = False

        text = task.get("text", "").strip()

        for id in task.get("assignees", []):
            enqueue_discord_dm(text, id, str(event_uid))
        new_state[task_key]["last_deadline_reminder_sent_at"] = now.isoformat()
        print("13e: queued reminder for", task_key)

    save_state(new_state)
    print("13: main finished")


if __name__ == "__main__":
    main()