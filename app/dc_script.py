"""
Polls NextCloud calendar via CalDAV sync token for newly created/modified VTODOs
and queues Discord DMs for TaskBot
"""
# normalize all dates to 11:59P.M. ?
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
from dotenv import load_dotenv  # type: ignore
from helpers import (
    build_task_text,
    cleanup_old_cache_files,
    completed,
    get_client,
    load_state,
    normalize_status,
    parse_deadline_value,
    save_state,
    utc_now_iso,
    get_secret,
    normalize_deadline,
    get_reminder_deltas,
    mark_due_reminder_deltas,
)

# fix 2026-07-27: poller pulls user maps from vault now, same helper as the bot
from vault import vault_get_user_map_dc

DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
QUEUE_DIR = DATA_DIR / "queue" / "pending"
QUEUE_DIR.mkdir(parents=True, exist_ok=True)
SYNC_TOKEN_DIR = DATA_DIR / "sync_tokens"
SYNC_TOKEN_DIR.mkdir(parents=True, exist_ok=True)

print("1: script started", flush=True)

# use env vars
load_dotenv(Path(__file__).resolve().parent / ".env")

# DISCORD_BOT_TOKEN = get_secret("DISCORD_BOT_TOKEN")
USER_MAP_DC = json.loads(get_secret("USER_MAP_DC", "{}"))
USER_MAP_SIGNAL = json.loads(get_secret("USER_MAP_SIGNAL", "{}"))

# CALENDAR_NAME = get_secret("CALENDAR_NAME")
# CALENDAR_URL = get_secret("CALENDAR_URL")

print("2: config loaded")
print("2b: USER_MAP keys =", list(USER_MAP_DC.keys()))


def sync_token_path(delegation_id: str) -> Path:
    return SYNC_TOKEN_DIR / f"{delegation_id}.txt"


def load_sync_token(delegation_id: str):
    path = sync_token_path(delegation_id)
    if not path.exists():
        return None
    return path.read_text().strip() or None


def save_sync_token(delegation_id: str, token):
    if token:
        sync_token_path(delegation_id).write_text(token)


# checks if it is time to send a reminder (check deltas or if task is new)
def should_send_reminder(task: dict, now: datetime, reminder_deltas: list[timedelta]):
    status = task.get("status", "pending")
    if normalize_status(status) == "done":
        return None
    if task.get("new"):
        return "new"
    if task.get("added_assignees") or task.get("removed_assignees"):
        return "assignee_change"
    if task.get("updated", {}):
        return "updated"

    deadline = parse_deadline_value(task.get("deadline"))
    if not deadline:
        return None

    # avoid duplicate sends
    sent_deltas = set(task.get("sent_reminder_deltas", []))
    print(sent_deltas)

    for delta in sorted(reminder_deltas, reverse=True):
        # if deadline hasn't passed
        if delta >= timedelta(0):
            reminder_time = deadline - delta
            delta_key = str(delta)
            print("delta key:", delta_key)
            if now >= reminder_time and delta_key not in sent_deltas:
                return delta_key
        # if deadline has passed and task is incomplete, send 1 daily reminder
        else:
            overdue_start = deadline + abs(delta)
            if now < overdue_start:
                continue

            overdue_days = (now.date() - overdue_start.date()).days + 1
            delta_key = f"overdue:{abs(delta).days}:{overdue_days}"
            if delta_key not in sent_deltas:
                return delta_key

    return None


# handoff layer for persistent TaskBot
def enqueue_discord_dm(
    text: str,
    discord_user_id: int,
    task_key: str,
    job_type: str = "send_task_dm",
    updated: dict = None,
):
    if not updated:
        updated = {}
    job = {
        "type": job_type,
        "discord_user_id": discord_user_id,
        "text": text,
        "task_key": task_key,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "updated": updated,
    }

    tmp_path = QUEUE_DIR / f"{uuid.uuid4()}.tmp"
    final_path = QUEUE_DIR / f"{uuid.uuid4()}.json"

    tmp_path.write_text(json.dumps(job, indent=2))
    tmp_path.rename(final_path)


def parse_vtodo(vtodo):
    print("vtodo:\n", vtodo)
    subject = str(vtodo.get("SUMMARY", "")).strip() or "Nextcloud event"
    description = (
        str(vtodo.get("DESCRIPTION", "")).strip() if vtodo.get("DESCRIPTION") else ""
    )
    location = str(vtodo.get("LOCATION", "")).strip()

    try:
        due = vtodo.decoded("DUE") if vtodo.get("DUE") else None
    except Exception:
        due = vtodo.get("DUE")

    deadline_text = (
        due.date().isoformat() if isinstance(due, datetime) else str(due or "")
    )

    parts = [subject]
    if description:
        parts.append(f"Description: {description}")
    if location:
        parts.append(f"Location: {location}")
    if deadline_text:
        parts.append(f"Deadline: {deadline_text}")

    return "\n".join(parts), subject, description, due


# store event info (importantly, event uid) once vtodo obtained
def store_event(task_key: str, delegation: dict, event, vtodo, text: str):
    state = load_state()
    task_key = str(task_key)

    old_assignees = []

    if task_key not in state:
        state[task_key] = {}
        state[task_key]["new"] = True
    else:
        # checking (below) if any assignees have been added or removed
        old_assignees = state[task_key].get("assignees", [])

        # check if any info is being modified to notify assignees; values updated below
        state[task_key]["updated"] = {}
        stored = normalize_deadline(state[task_key].get("deadline"))
        current_due = None
        try:
            current_due = vtodo.decoded("DUE") if vtodo.get("DUE") else None
        except Exception:
            current_due = vtodo.get("DUE")
        current = normalize_deadline(current_due)
        print("stored: ", stored)
        print("current: ", current)
        if stored and current != stored:
            state[task_key]["updated"]["deadline"] = True

        for field in ["LOCATION", "STATUS", "SUBJECT", "DESCRIPTION"]:
            actual = "SUMMARY" if field == "SUBJECT" else field
            field = field.lower()

            if field == "STATUS":
                current_value = normalize_status(vtodo.get(actual))
                stored_value = normalize_status(state[task_key].get("status", ""))
            else:
                current_value = str(vtodo.get(actual, "") or "").strip()
                stored_value = str(state[task_key].get(f"{field}", "")).strip()

            if stored_value and current_value != stored_value:
                print(
                    "changed:",
                    field,
                    "stored=",
                    stored_value,
                    "current=",
                    current_value,
                )
                state[task_key]["updated"][field] = True

    due = vtodo.decoded("DUE").isoformat() if vtodo.get("DUE") else None

    # allowing multiple delegators and calendars
    state[task_key]["delegation_id"] = str(delegation.get("id", "")).strip()
    state[task_key]["calendar_name"] = (
        str(delegation.get("calendar_name", "")).strip().lower()
    )
    state[task_key]["calendar_url"] = str(delegation.get("calendar_url", "")).strip()
    state[task_key]["delegator_discord_id"] = str(
        delegation.get("delegator_discord_id", "")
    ).strip()
    state[task_key]["delegator_signal_key"] = str(
        delegation.get("delegator_signal_key", "")
    ).strip()

    state[task_key]["status"] = (
        str(vtodo.get("STATUS", "")).strip() if vtodo.get("STATUS") else "pending"
    )
    state[task_key]["object_type"] = "caldav_event"
    state[task_key]["object_id"] = str(vtodo.get("UID", "")).strip()
    state[task_key]["event_uid"] = str(vtodo.get("UID", "")).strip()
    state[task_key]["event_url"] = str(getattr(event, "url", ""))
    state[task_key]["deadline"] = (
        due.isoformat() if hasattr(due, "isoformat") else str(due or "")
    )
    state[task_key]["location"] = (
        str(vtodo.get("LOCATION", "")).strip() if vtodo.get("LOCATION") else ""
    )
    state[task_key]["subject"] = str(vtodo.get("SUMMARY", "")).strip()
    state[task_key]["description"] = (
        str(vtodo.get("DESCRIPTION", "")).strip() if vtodo.get("DESCRIPTION") else ""
    )
    state[task_key]["notification_id"] = task_key
    state[task_key]["text"] = text
    state[task_key]["notification_datetime"] = datetime.now(timezone.utc).isoformat()

    # INITIALIZING
    state[task_key].setdefault("discord_messages", {})
    state[task_key].setdefault("assignees", [])
    state[task_key].setdefault("previous_message_ids", {})
    state[task_key].setdefault("sent_reminder_deltas", [])

    # in case user map updated via slash command
    delegation_id = str(delegation.get("id", "")).strip()
    # fix 2026-07-27: read an env var nothing set, so the map was always empty
    try:
        user_map_dc = vault_get_user_map_dc(delegation_id)
    except Exception as e:
        print("12w: user map fetch failed for", delegation_id, repr(e))
        user_map_dc = {}
    print("user map:", user_map_dc)
    assignees = []
    # storing delegator and assignee discord/signal id
    if vtodo.get("CATEGORIES", []):
        assignees = [
            user_map_dc.get(str(a).strip().lower(), "")
            for a in vtodo.get("CATEGORIES", [])
        ]
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

    with get_client() as client:
        # for each delegator:calendar
        for delegation in json.loads(get_secret("DELEGATIONS_JSON", "[]")):
            delegation_id = str(delegation.get("id", "")).strip()
            calendar_name = str(delegation.get("calendar_name", "")).strip()
            calendar_url = str(delegation.get("calendar_url", "")).strip()

            if not delegation_id or not calendar_url:
                print("8x: skipping invalid delegation config:", delegation)
                continue

            print("before get_calendar", delegation_id, flush=True)
            calendar = client.calendar(url=calendar_url)
            print("after get_calendar", delegation_id, flush=True)
            print("calendar =", repr(calendar), flush=True)
            print("calendar is None =", calendar is None, flush=True)

            if calendar is None:
                continue

            old_token = load_sync_token(delegation_id)
            print("8a:", delegation_id, "old_token =", old_token)

            # creating token
            if not old_token:
                print(
                    "8d: no old token yet for",
                    delegation_id,
                    "- saving initial token and skipping initial send",
                )
                changes = calendar.get_objects(load_objects=True)
                print(
                    "initial sync_token =",
                    repr(getattr(changes, "sync_token", None)),
                    flush=True,
                )
                save_sync_token(delegation_id, getattr(changes, "sync_token", None))
                old_token = load_sync_token(delegation_id)
                print("reloaded token =", repr(old_token), flush=True)

            # find new/modified objects
            try:
                print("before get_objects", delegation_id, flush=True)
                changes = calendar.get_objects(
                    sync_token=old_token, load_objects=True, disable_fallback=True
                )
                print("after get_objects", delegation_id, flush=True)
            except Exception as e:
                print("8x: get_objects failed for", calendar_name, repr(e))
                continue

            print("changes:\n", changes)

            # parse events
            for event in changes:
                try:
                    vtodo = event.get_icalendar_component()
                    print(event.get_icalendar_component(), "\n")
                    print(event.get_icalendar_instance(), "\n")
                    print("vobj: ", event.get_vobject_instance(), "\n")
                    print("done print")
                except Exception as e:
                    print("8y: skipping non-vtodo or bad vobject", repr(e))
                    continue

                print("event candidate:\n", event)

                uid = str(vtodo.get("UID", "")).strip()
                print("UID: ", uid)

                if not uid:
                    print("8z: skipping because missing uid")
                    continue

                changed_items.append((delegation, event, vtodo))

            save_sync_token(delegation_id, getattr(changes, "sync_token", None))

    return changed_items


def main():
    print("10: entering main")
    cleanup_old_cache_files()

    changed_items = sync_calendar()
    print("10b: changed_items =", len(changed_items))

    # first refresh/update local state from any synced calendar changes
    for delegation, event, vtodo in changed_items:
        event_uid = str(vtodo.get("UID", "")).strip()
        print("11: raw event_uid =", event_uid)

        if not event_uid:
            print("11a: skipping because missing uid")
            continue

        text, subject, description, deadline = parse_vtodo(vtodo)
        print("12a: subject =", subject)
        print("12b: description =", description)
        print("12c: deadline =", deadline)

        store_event(event_uid, delegation, event, vtodo, text)

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
        # new task
        job_type = None
        if due in ("new", "assignee_change"):
            job_type = "send_task_dm"
            new_state[task_key]["new"] = False
            new_state[task_key].setdefault("sent_reminder_deltas", [])
            # add multiple valid sent deltas at once if item due soon after creation
            mark_due_reminder_deltas(new_state[task_key], now, reminder_deltas)
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
                    update_text += f"New {field}: {task[field].split('T')[0] \
                                if field == 'deadline' else task[field]}.\n"
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
                user_text = (
                    "You have been removed from the following task:\n" + base_text
                )
                user_job_type = "send_task_followup_dm"
                if discord_id in new_state[task_key].get("removed_assignees", []):
                    new_state[task_key]["removed_assignees"].remove(discord_id)
                enqueue_discord_dm(
                    user_text,
                    discord_id,
                    task_key,
                    user_job_type,
                    task.get("updated", {}),
                )
                continue

            if added and discord_id in added:
                user_text = "You have been added to the following task:\n" + base_text
                if discord_id in new_state[task_key].get("added_assignees", []):
                    new_state[task_key]["added_assignees"].remove(discord_id)
                # new assignee should get canonical message with interactions
                enqueue_discord_dm(
                    user_text,
                    discord_id,
                    task_key,
                    "send_task_dm",
                    task.get("updated", {}),
                )
                continue

            enqueue_discord_dm(
                user_text, discord_id, task_key, user_job_type, task.get("updated", {})
            )

        new_state[task_key]["added_assignees"] = []
        new_state[task_key]["removed_assignees"] = []
        new_state[task_key]["updated"] = {}

        print("13e: queued reminder for", task_key)

    save_state(new_state)
    print("13: main finished")


if __name__ == "__main__":
    main()
