"""
Polls NextCloud calendar via CalDAV sync token for newly created/modified VTODOs
and queues Discord DMs for TaskBot 
"""
# TODO: test reminder deltas
# test: fix followup reminder spam; reminders being sent whenever a task is sent or script is run

# server-side failure handling: 
# script fails to fetch events from sync token -> cron reschedules script -> eventual success
# bot fails to send dm/sync an update to NC -> update goes into processing queue to be retried
        # IMPORTANT: increase sleep times between enqueues to avoid performance overload

#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import uuid
import json
from dotenv import load_dotenv # type: ignore
from helpers import (
    build_task_text,
    cleanup_old_cache_files,
    completed,
    get_client,
    load_state,
    save_state,
    utc_now_iso,
)

QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)
SYNC_TOKEN_FILE = Path("calendar_sync_token.txt")

print("1: script started", flush=True)

# use env vars
load_dotenv(Path(__file__).resolve().parent / ".env")

REMINDER_HOURS_BEFORE = int(os.getenv("REMINDER_HOURS_BEFORE", "24"))
REMINDER_DAYS_BEFORE = int(os.getenv("REMINDER_DAYS_BEFORE", "0"))
REMINDER_DELTAS = json.loads(os.getenv("REMINDER_DELTAS", "[]"))

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


def get_reminder_deltas():
    if REMINDER_DELTAS:
        return [timedelta(days=d, hours=h) for d, h in REMINDER_DELTAS]
    return [timedelta(days=REMINDER_DAYS_BEFORE, hours=REMINDER_HOURS_BEFORE)]


def normalize_deadline(value):
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value).strip()


# checks if it is time to send a reminder (check deltas or if task is new)
def should_send_reminder(task: dict, now: datetime, reminder_deltas: list[timedelta]):
    status = task.get("status", "pending")
    if status == "done":
        return None
    if task.get("new"):
        return "new"
    if task.get("added_assignees") or task.get("removed_assignees"):
        return "assignee_change"
    if task.get("updated", False):
        return "updated"

    deadline = parse_deadline_value(task.get("deadline"))
    if not deadline:
        return None

    # avoid duplicate sends
    sent_deltas = set(task.get("sent_reminder_deltas", []))
    print(sent_deltas)

    for delta in sorted(reminder_deltas, reverse=True):
        reminder_time = deadline - delta
        delta_key = str(delta)
        print("delta key:", delta_key)
        if now >= reminder_time and delta_key not in sent_deltas:
            return delta_key

    return None


# handoff layer for persistent TaskBot
def enqueue_discord_dm(text: str, discord_user_id: int, task_key: str, job_type: str = "send_task_dm", updated: dict = None):
    if not updated:
        updated = {}
    job = {
        "type": job_type,
        "discord_user_id": discord_user_id,
        "text": text,
        "task_key": task_key,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "updated": updated
    }

    tmp_path = QUEUE_DIR / f"{uuid.uuid4()}.tmp"
    final_path = QUEUE_DIR / f"{uuid.uuid4()}.json"

    tmp_path.write_text(json.dumps(job, indent=2))
    tmp_path.rename(final_path)


def parse_vtodo(vtodo):
    print("vtodo:\n", vtodo)
    subject = str(vtodo.get("SUMMARY", "")).strip() or "Nextcloud event"
    description = str(vtodo.get("DESCRIPTION", "")).strip() if vtodo.get("DESCRIPTION") else ""
    location = str(vtodo.get("LOCATION", "")).strip()

    try:
        due = vtodo.decoded("DUE") if vtodo.get("DUE") else None
    except Exception:
        due = vtodo.get("DUE")

    deadline_text = due.date().isoformat() if isinstance(due, datetime) else str(due or "")

    parts = [subject]
    if description:
        parts.append(f"Description: {description}")
    if location:
        parts.append(f"Location: {location}")
    if deadline_text:
        parts.append(f"Deadline: {deadline_text}")

    return "\n".join(parts), subject, description, due


# store event info (importantly, event uid) once vtodo obtained
def store_event(task_key: str, calendar_name: str, event, vtodo, text: str):
    state = load_state()
    task_key = str(task_key)

    old_assignees = []

    if task_key not in state:
        state[task_key] = {}
        state[task_key]["new"] = True
    else:
        # checking (below) if any assignees have been added or removed
        old_assignees = state[task_key].get("assignees", "")

        # check if any info is being modified to notify assignees; values updated below
        state[task_key]["updated"] = {}
        stored = normalize_deadline(state[task_key].get("deadline"))
        current = normalize_deadline(vtodo.get("DUE"))
        print("stored: ", stored)
        print("current: ", current)
        if stored and current != stored:
            state[task_key]["updated"]["deadline"] = True
        
        for field in ["LOCATION", "STATUS", "SUBJECT", "DESCRIPTION"]:
                if field == "SUBJECT": actual = "SUMMARY"
                else: actual = field
                field = field.lower()

                if state[task_key].get(field, "") and vtodo.get(actual) != state[task_key][field]: 
                    print(vtodo.get(actual))
                    print(state[task_key][field])
                    state[task_key]["updated"][field] = True

    due = vtodo.decoded("DUE").isoformat() if vtodo.get("DUE") else None

    state[task_key]["calendar_name"] = (calendar_name or "").strip().lower()
    state[task_key]["status"] = str(vtodo.get("STATUS", "")).strip() if vtodo.get("STATUS") else "pending"
    state[task_key]["object_type"] = "caldav_event"
    state[task_key]["object_id"] = str(vtodo.get("UID", "")).strip()
    state[task_key]["event_uid"] = str(vtodo.get("UID", "")).strip()
    state[task_key]["event_url"] = str(getattr(event, "url", ""))
    state[task_key]["deadline"] = due.isoformat() if hasattr(due, "isoformat") else str(due or "")
    state[task_key]["location"] = str(vtodo.get("LOCATION", "")).strip() if vtodo.get("LOCATION") else ""
    state[task_key]["subject"] = str(vtodo.get("SUMMARY", "")).strip()
    state[task_key]["description"] = str(vtodo.get("DESCRIPTION", "")).strip() if vtodo.get("DESCRIPTION") else ""
    state[task_key]["notification_id"] = task_key
    state[task_key]["text"] = text
    state[task_key]["notification_datetime"] = datetime.now(timezone.utc).isoformat()

    # INITIALIZING
    state[task_key].setdefault("discord_messages", {})
    state[task_key].setdefault("assignees", [])
    state[task_key].setdefault("previous_message_ids", {})
    state[task_key].setdefault("sent_reminder_deltas", [])

    assignees = []
    # storing delegator and assignee discord/signal ids
    if vtodo.get("CATEGORIES", []):
        assignees = [USER_MAP_DC.get(str(a).strip().lower(), "") for a in vtodo.get("CATEGORIES", [])]
        assignees = [a for a in assignees if a]
        # removing all assignees results in no "CATERGORIES" param

    if old_assignees != assignees:
        # if assignees:
            added = list(set(assignees) - set(old_assignees))
            removed = list(set(old_assignees) - set(assignees))
            if added:
                state[task_key]["added_assignees"] = added
                for a in added:
                    state[task_key]["assignees"].append(a)
            if removed:
                state[task_key]["removed_assignees"] = removed
                # looping to preserve existing message_ids
                for a in removed:
                    state[task_key]["assignees"].remove(a)
    # brand new task; redundant?
    if not old_assignees: 
        state[task_key]["assignees"] = list(assignees)
        
    save_state(state)

    print("12x: object_type =", state[task_key]["object_type"])
    print("12y: object_id =", state[task_key]["object_id"])
    print("12z: calendar_name =", state[task_key]["calendar_name"])


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
            # load_objects increases immediate overhead but is necessary for accessing vTODOs
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
                    # vtodo = event.vobject_instance.vtodo
                    vtodo = event.get_icalendar_component() # read-only
                    print(event.get_icalendar_component(), "\n")
                    print(event.get_icalendar_instance(), "\n")
                    print("vobj: ", event.get_vobject_instance(), "\n")
                    
                    print("done print")
                except Exception as e:
                    print("8y: skipping non-vtodo or bad vobject", repr(e))
                    continue

                print("event candidate:\n", event)

                # uid = getattr(vtodo.uid, "value", "") if getattr(vtodo, "UID", None) else ""
                uid = str(vtodo.get("UID", ""))
                print("UID: ", uid)

                if not uid:
                    print("8z: skipping because missing uid")
                    continue

                changed_items.append((CALENDAR_NAME, event, vtodo))

            save_sync_token(getattr(changes, "sync_token", None))

    return changed_items


def main():
    print("10: entering main")
    cleanup_old_cache_files()

    changed_items = sync_calendar()
    print("10b: changed_items =", len(changed_items))

    # first refresh/update local state from any synced calendar changes
    for calendar_name, event, vtodo in changed_items:
        event_uid = str(vtodo.get("UID", "")).strip()
        print("11: raw event_uid =", event_uid)

        if not event_uid:
            print("11a: skipping because missing uid")
            continue

        text, subject, description, deadline = parse_vtodo(vtodo)
        print("12a: subject =", subject)
        print("12b: description =", description)
        print("12c: deadline =", deadline)

        store_event(event_uid, calendar_name, event, vtodo, text)
        
        # no longer need merge for notif IDs; event_uid now canonical uid from the start
        # final_task_key = merge_task_into_event_uid(str(event_uid), str(event_uid))
        print("12d: synced event into state =", event_uid)

    # then scan all active tasks and send reminders if inside configured window
    reminder_deltas = get_reminder_deltas()
    now = datetime.now(timezone.utc)
    print("13a: now =", now.isoformat())
    print("13b: reminder_delta =", reminder_deltas)

    state = load_state()

    new_state = {}
    for task_key, task in state.items():
        if not isinstance(task, dict):
            continue

        # delete stale completed tasks
        if completed(task_key, 1):
            print("deleting stale task: ", task_key)
            continue
        new_state[task_key] = dict(task)

        print("13c: checking task_key =", task_key)

        # skips if reminder not due and no modificactions to task have been recorded
        due = should_send_reminder(task, now, reminder_deltas)
        if not due:
            print("13d: reminder not due for", task_key)
            continue
        
        base_text = build_task_text(task)
        text = base_text

        print("due: ", due)
        # new task; TODO: make states more clear/explicit and narrow down to one canonical stream
        if due == "new" or due == "assignee_change":
            job_type = "send_task_dm"
            new_state[task_key]["new"] = False
        # update notif; don't touch routine reminder state/logic
        elif due == "updated":
            print("ITEM UPDATE!\n")
            job_type = "send_task_followup_dm"
            # checking if info has been updated and notifying assignees
            update_text = ""
            if task.get("updated", {}):
                print("task marked as updated")
            for field in ["deadline", "location", "status", "subject", "description"]:
                if task["updated"].get(field, False):
                    if task[field] == "pending":
                        continue
                    update_text += f"New {field}: {task[field].split('T')[0] if field == 'deadline' else task[field]}.\n"
                    new_state[task_key]["updated"][field] = False
            if update_text:
                text = "This task has been updated.\n" + update_text + "\n"
            else:
                continue  # don't send unnecessary update msgs (always sends when status pending)
            print(text)
        # routine reminder notif
        elif due:
            print("ITEM DUE!\n")
            job_type = "send_task_followup_dm"
            text = "Reminder:\n" + base_text
            new_state[task_key].setdefault("sent_reminder_deltas", [])
            if due in new_state[task_key]["sent_reminder_deltas"]:
                continue
            new_state[task_key]["sent_reminder_deltas"].append(due)
            new_state[task_key]["last_deadline_reminder_sent_at"] = utc_now_iso()

        removed = list(task.get("removed_assignees", []))
        added = list(task.get("added_assignees", []))

        for discord_id in list(task.get("assignees", [])) + removed:
            user_text = text
            user_job_type = job_type

            # notify of removal from task
            if removed and discord_id in removed:
                user_text = "You have been removed from the following task:\n" + base_text
                user_job_type = "send_task_followup_dm"
                if discord_id in new_state[task_key].get("removed_assignees", []):
                    new_state[task_key]["removed_assignees"].remove(discord_id)
                enqueue_discord_dm(user_text, discord_id, task_key, user_job_type, task.get("updated", {}))
                continue

            if added and discord_id in added:
                user_text = "You have been added to the following task:\n" + base_text
                if discord_id in new_state[task_key].get("added_assignees", []):
                    new_state[task_key]["added_assignees"].remove(discord_id)
                # new assignee should get canonical message with interactions
                enqueue_discord_dm(user_text, discord_id, task_key, "send_task_dm", task.get("updated", {}))
                continue

            enqueue_discord_dm(user_text, discord_id, task_key, user_job_type, task.get("updated", {}))

        new_state[task_key]["added_assignees"] = []
        new_state[task_key]["removed_assignees"] = []
        new_state[task_key]["updated"] = {}

        print("13e: queued reminder for", task_key)

    save_state(new_state)
    print("13: main finished")


if __name__ == "__main__":
    main()