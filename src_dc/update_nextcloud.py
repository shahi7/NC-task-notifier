"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
import os
import caldav # type: ignore
from helpers import completed_timestamp, get_client, load_state, utc_now_iso, save_state
from icalendar import Calendar, vText # type: ignore
CALENDAR_NAME = os.getenv("CALENDAR_NAME")
CALENDAR_URL = os.getenv("CALENDAR_URL")

def update_nextcloud_task_old(task_key: str, action: str):
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
        if not event_uid:
            return False, "No saved event_uid for this task."
        
        calendar_name = task["calendar_name"]
        principal = client.principal()
        calendar = next(
            (c for c in principal.calendars() if (c.get_display_name() or "").strip().lower() == calendar_name),
            None,
        )
        todo = calendar.get_todo_by_uid(event_uid)
        
        #        vobj.vevent.status.value = 'COMPLETED'
        # event.save()

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

        

        # locating primary vevent object
        vevent = next(
            (
                c for c in calendar.subcomponents
                if c.name == "VEVENT" and "RECURRENCE-ID" not in c  # "VTODO"
            ),
            None,
        )

        if vevent is None:
                return False, "No main VEVENT found."
        
        # updating event color: CHECK IF WORKING
        # TODO cannot find color property in docs

    return True, f"Marked as **{action}**."


def update_nextcloud_task(task_key: str, action: str):
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
    with caldav.get_calendar(calendar_name=CALENDAR_NAME, url=CALENDAR_URL) as calendar:
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


