"""
Updates task state to NextCloud server
"""

import asyncio
from datetime import datetime
import json
import os
from pathlib import Path
import uuid
import requests  # type: ignore
from helpers import (
    completed_timestamp,
    get_client,
    load_state,
    utc_now_iso,
    save_state,
    normalize_status,
    get_secret,
)
from caldav.calendarobjectresource import Todo  # type: ignore

print(Todo)

CALENDAR_NAME = get_secret("CALENDAR_NAME")
CALENDAR_URL = get_secret("CALENDAR_URL")

RETRYABLE_ERRORS = (
    ConnectionError,
    TimeoutError,
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
)

DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
NC_QUEUE_DIR = DATA_DIR / "NCqueue"
NC_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
# NC_UPDATE_QUEUE = Path("NCupdate_queue.json")


# in case of temporary server-side connection errors
async def update_and_retry(
    task_key: str,
    new_status: str,
    allow_requeue: bool = True,
    deadline: str = "",
    retries: int = 5,
):
    last_exc = None
    for attempt in range(retries):
        try:
            ok, message = await asyncio.to_thread(
                update_nextcloud_task, task_key, new_status, deadline
            )
            if not ok:
                raise RuntimeError(message or "Nextcloud update failed")
            return ok, message
        except RETRYABLE_ERRORS as e:
            last_exc = e
            if attempt == retries - 1:
                break
            await asyncio.sleep(2**attempt)  # 1s, 2s, 4s

    # queue after retries fail; does not queue more than once
    print("queueing to retry on rerun")
    if allow_requeue:
        tmp_path = NC_QUEUE_DIR / f"{uuid.uuid4()}.tmp"
        final_path = NC_QUEUE_DIR / f"{uuid.uuid4()}.json"
        job = {
            "task_key": task_key,
            "new_status": new_status,
            "deadline": deadline,
            "allow_requeue": allow_requeue,
        }
        tmp_path.write_text(json.dumps(job, indent=2))
        tmp_path.rename(final_path)

    raise last_exc


async def process_update_queue():
    # just try queued jobs first? instead of FIFO
    for path in sorted(NC_QUEUE_DIR.glob("*.json")):
        try:
            processing_path = NC_QUEUE_DIR / path.name
            try:
                path.rename(processing_path)
            except FileNotFoundError:
                continue
            job = json.loads(processing_path.read_text())
            await update_and_retry(
                job["task_key"],
                job["new_status"],
                allow_requeue=job.get("allow_requeue", False),
                deadline=job.get("deadline", ""),
            )
            processing_path.unlink()
        except Exception as e:
            print(f"Queued NC update still failing for {path.name}: {e}")


def update_nextcloud_task(task_key: str, action: str = "", deadline: str = ""):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, "Task not found."

    completed_timestamp(task_key, action)

    calendar_url = str(task.get("calendar_url", "")).strip()
    if not calendar_url:
        return False, "Calendar URL not found in task state."

    with get_client() as client:
        calendar = client.calendar(url=calendar_url)
        if calendar is None:
            return False, "Calendar not found."

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
        except Exception as e:
            print("Failed to fetch item as VTODO", repr(e))
            return False, ""

        # edit_icalendar_instance() alt
        with todo.edit_vobject_instance() as vobj:
            print("\nedit vobj\n")
            # update deadline
            if deadline:
                print(deadline)
                new_due = datetime.fromisoformat(deadline)
                print(new_due)
                if hasattr(vobj.vtodo, "due"):
                    vobj.vtodo.due.value = new_due
                else:
                    vobj.vtodo.add("due").value = new_due
                # fresh reminder deltas for new deadline
                state[task_key]["sent_reminder_deltas"] = []
                state[task_key]["last_deadline_reminder_sent_at"] = None

            if action:
                n_status = normalize_status(action)
                print("\naction update\n")
                print(n_status)
                print(normalize_status(task["status"]))
                print("\naction\n")
                # print(vobj.vtodo.status.value)
                if not hasattr(vobj.vtodo, "status"):
                    print("has attr")
                    vobj.vtodo.add("status").value = "NEEDS-ACTION"
                if normalize_status(task["status"]) != n_status:
                    print("doing")
                    print(vobj.vtodo.status.value)
                    vobj.vtodo.status.value = "NEEDS-ACTION"
                    # handle interaction
                    if n_status == "done":
                        todo.complete()
                        vobj.vtodo.status.value = "COMPLETED"
                    # handle cancellations
                    else:
                        if normalize_status(task["status"]) == "done":  # undo complete
                            todo.uncomplete()

                        if n_status == "pending":
                            vobj.vtodo.status.value = "NEEDS-ACTION"
                        elif n_status == "working":
                            print("\nmarekin\n")
                            vobj.vtodo.status.value = "IN-PROCESS"
                        else:  # cancelled
                            vobj.vtodo.status.value = "CANCELLED"

        print("\ndone updating NC\n")
        todo.save()

        if action:
            task["status"] = n_status
        state[task_key]["workflow_updated_at"] = utc_now_iso()
        state[task_key]["nextcloud_update"] = {
            "pending": True,
            "action": action,
            "object_type": task.get("object_type"),
            "object_id": task.get("object_id"),
            "notification_id": task.get("notification_id"),
        }
        if deadline:
            state[task_key]["deadline"] = deadline
        save_state(state)

    return True, f"Marked as **{action}**."
