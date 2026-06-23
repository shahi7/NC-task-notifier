"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
import os
from caldav import get_calendar # type: ignore
from helpers import completed_timestamp, get_client, load_state, utc_now_iso, save_state
from icalendar import Calendar, vText # type: ignore
CALENDAR_NAME = os.getenv("CALENDAR_NAME")
CALENDAR_URL = os.getenv("CALENDAR_URL")


def update_nextcloud(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f"Unknown task key: {task_key}"

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

    # fetch user info
    with get_client() as client:
        calendar = client.calendar(url=CALENDAR_URL)
        if calendar:
                try:
                      todo = calendar.get_todo_by_uid(event_uid)
                except Exception as e:
                      print("Failed to fetch item as VTODO", repr(e))
                      return False, ""

        with todo.edit_vobject_instance() as vobj:
                # handle interaction
                if action == "done":
                        todo.complete()
                        vobj.vtodo.status.value = 'COMPLETED'
                # handle cancellations 
                else:
                        todo.uncomplete()
                        if action == "pending":
                              vobj.vtodo.status.value = 'PENDING'
                        elif action == "working":
                              vobj.vtodo.status.value = 'IN-PROGRESS'
                        else:
                              vobj.vtodo.status.value = 'CANCELLED'
                              
        todo.save()

    return True, f"Marked as **{action}**."


