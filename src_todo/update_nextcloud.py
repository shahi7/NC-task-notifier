"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
import asyncio
import os
import requests # type: ignore
from caldav import get_calendar # type: ignore
from helpers import completed_timestamp, get_client, load_state, utc_now_iso, save_state
from icalendar import Calendar, vText # type: ignore
CALENDAR_NAME = os.getenv("CALENDAR_NAME")
CALENDAR_URL = os.getenv("CALENDAR_URL")

RETRYABLE_ERRORS = (
    ConnectionError,
    TimeoutError,
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
)

async def update_and_retry(task_key: str, new_status: str, retries: int = 3):
    last_exc = None
    for attempt in range(retries):
        try:
            return await asyncio.to_thread(update_nextcloud_task, task_key, new_status)
        except RETRYABLE_ERRORS as e:
            last_exc = e
            if attempt == retries - 1:
                break
            await asyncio.sleep(2 ** attempt)   # 1s, 2s, 4s
    raise last_exc


def update_nextcloud_task(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f""

    completed_timestamp(task_key, action)

    task["status"] = action
    task["workflow_updated_at"] = utc_now_iso()
    task["nextcloud_update"] = {
        "pending": True,
        "action": action,
        "object_type": task.get("object_type"),
        "object_id": task.get("object_id"),
        "notification_id": task.get("notification_id"),
    }
    save_state(state)

    event_uid = task.get("event_uid")
    if not event_uid:
        return False, ""

    with get_client() as client:
        calendar = client.calendar(url=CALENDAR_URL)
        if calendar is None:
            return False, ""

        try:
            todo = calendar.todo_by_uid(event_uid)
        except Exception as e:
            print("Failed to fetch item as VTODO", repr(e))
            return False, ""

        with todo.edit_vobject_instance() as vobj:
                # handle interaction
                if action == "done":
                        todo.complete()
                        vobj.vevent.status.value = 'COMPLETED'
                # handle cancellations 
                else:
                        todo.uncomplete()
                        if action == "pending":
                              vobj.vevent.status.value = 'PENDING'
                        elif action == "working":
                              vobj.vevent.status.value = 'IN-PROGRESS'
                        else:
                              vobj.vevent.status.value = 'CANCELLED'
                              
        todo.save()

    return True, f"Marked as **{action}**."