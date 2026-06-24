"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
import asyncio
from datetime import datetime
import os
import requests # type: ignore
from helpers import completed_timestamp, get_client, load_state, utc_now_iso, save_state
from caldav.calendarobjectresource import Todo # type: ignore
print(Todo)

CALENDAR_NAME = os.getenv("CALENDAR_NAME")
CALENDAR_URL = os.getenv("CALENDAR_URL")

RETRYABLE_ERRORS = (
    ConnectionError,
    TimeoutError,
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
)

async def update_and_retry(task_key: str, new_status: str, deadline: str = "", retries: int = 3):
    last_exc = None
    for attempt in range(retries):
        try:
            return await asyncio.to_thread(update_nextcloud_task, task_key, new_status, deadline)
        except RETRYABLE_ERRORS as e:
            last_exc = e
            if attempt == retries - 1:
                break
            await asyncio.sleep(2 ** attempt)   # 1s, 2s, 4s
    raise last_exc


def update_nextcloud_task(task_key: str, action: str, deadline: str = ""):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f""

    completed_timestamp(task_key, action)

    event_uid = task.get("event_uid")
    if not event_uid:
        return False, ""

    with get_client() as client:
        calendar = client.calendar(url=CALENDAR_URL)
        if calendar is None:
            return False, ""

        # get event object (encapsulating vTODO) by UID first?
        try:
            # constructing and loading Todo via URL; UID lookup failing
            todo = Todo(client=client, url=task.get("event_url"), parent=calendar)
            todo.load()
            # up-to-date UID
            print(todo)
            print(task["event_uid"])
            task["event_uid"] = todo.id
            print(task["event_uid"])
            # TODO: use .data/get_data() and icalendar to parse raw ics string for UID
            # todo = calendar.get_todo_by_uid(event_uid)
            # print(todo)
            # todo = calendar.search(todo=True, uid=event_uid)
        except Exception as e:
            print("Failed to fetch item as VTODO", repr(e))
            return False, ""

        # edit_icalendar_instance() alt
        with todo.edit_vobject_instance() as vobj:
                # update deadline
                if deadline:
                     new_due = datetime.fromisoformat(deadline)
                     vt = vobj.vtodo
                     if hasattr(vt, "due"):
                         vt.due.value = new_due
                     else:
                         vt.add("due").value = new_due
                     # fresh reminder deltas for new deadline
                     task["sent_reminder_deltas"] = []
                     task["last_deadline_reminder_sent_at"] = None

                if task["status"] != action:
                        # handle interaction
                        if action == "done":
                                todo.complete()
                                vobj.vtodo.status.value = 'COMPLETED'
                        # handle cancellations 
                        else:
                                todo.uncomplete()
                                if action == "pending":
                                        vobj.vtodo.status.value = 'NEEDS-ACTION'
                                elif action == "working":
                                        vobj.vtodo.status.value = 'IN-PROCESS'
                                else:
                                        vobj.vtodo.status.value = 'CANCELLED'
                                
        todo.save()

        task["status"] = action
        task["workflow_updated_at"] = utc_now_iso()
        task["nextcloud_update"] = {
                "pending": True,
                "action": action,
                "object_type": task.get("object_type"),
                "object_id": task.get("object_id"),
                "notification_id": task.get("notification_id"),
        }
        if deadline: task["deadline"] = deadline
        save_state(state)

    return True, f"Marked as **{action}**."