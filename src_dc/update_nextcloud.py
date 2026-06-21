"""
Updates task state to NextCloud server
"""

# TODO use object_id, need calendar_name for CALDAV url, need event UID/URL, find color property
from src.helpers import load_state, utc_now_iso, save_state
import caldav # type: ignore
from icalendar import Calendar, vText # type: ignore
import os

def update_nextcloud_task(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f"Unknown task key: {task_key}"

    # check if action is undone
    if state["workflow_status"] == action:
        state["workflow_status"] = ""
        state["workflow_updated_at"] = utc_now_iso()
        state["nextcloud_update"] = {
                "pending": True
        }

    state["workflow_status"] = action
    state["workflow_updated_at"] = utc_now_iso()
    state["nextcloud_update"] = {
        "pending": True,
        "action": action,
        "object_type": state.get("object_type"),
        "object_id": state.get("object_id"),
        "notification_id": state.get("notification_id"),
    }

    save_state(state)

    object_id = task.get("object_id")

    # fetch user info
    with caldav.DAVClient(
        url=os.getenv("NEXTCLOUD_URL").rstrip("/") + "/remote.php/dav/calendars/" + os.getenv("NEXTCLOUD_USER") + "/",
        username=os.getenv("NEXTCLOUD_USER"),
        password=os.getenv("NEXTCLOUD_PASS")
    ) as client:
        my_principal = client.principal()
        # finding calendar using name (parsed from notification)
        calendar = next(
            filter(
                lambda calendar: calendar.name.lower() == state[task_key]["calendar_name"], my_principal.calendars()
            )
        )
        if calendar is None:
            raise ValueError("Could not find calendar by the name you provided")
        
        # fetching event
        event_url = f"{calendar.url}{object_id}.ics"
        event = client.calendar(url=event_url).event_by_url(event_url)

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