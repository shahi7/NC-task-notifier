"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
from helpers import get_client, load_state, utc_now_iso, save_state
from icalendar import Calendar, vText # type: ignore

def update_nextcloud_task(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f"Unknown task key: {task_key}"

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

    event_url = task.get("event_url")

    # fetch user info
    with get_client() as client:
        if not event_url:
            return False, "No saved event_url for this task."

        event = client.event_by_url(event_url)
        cal = Calendar.from_ical(event.data)

        # locating primary vevent object
        vevent = next(
            (
                c for c in cal.subcomponents
                if c.name == "VEVENT" and "RECURRENCE-ID" not in c
            ),
            None,
        )

        if vevent is None:
                return False, "No main VEVENT found."
        
        # updating event color: CHECK IF WORKING
        # TODO cannot find color property in docs
        # handle cancellations
        if action == "working" and vevent["STATUS"] == vText("TENTATIVE"):
                vevent["STATUS"] = vText("PENDING")
                vevent["COLOR"] = vText("blue")
        elif action == "done" and vevent["STATUS"] == vText("CONFIRMED"):
                vevent["STATUS"] = vText("PENDING")
                vevent["COLOR"] = vText("blue")
        # handle interaction
        if action == "working":
                vevent["STATUS"] = vText("TENTATIVE")
                vevent["COLOR"] = vText("yellow")
        elif action == "done":
                vevent["STATUS"] = vText("CONFIRMED")
                vevent["COLOR"] = vText("green")

        # syncing updated event
        event.data = cal.to_ical().decode("utf-8")
        event.save()

    return True, f"Marked as **{action}**."