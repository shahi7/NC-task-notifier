# TODO
from src.helpers import load_state, utc_now_iso, save_state

def update_nextcloud_task(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f"Unknown task key: {task_key}"

    task["workflow_status"] = action
    task["workflow_updated_at"] = utc_now_iso()
    task["nextcloud_update"] = {
        "pending": True,
        "action": action,
        "object_type": task.get("object_type"),
        "object_id": task.get("object_id"),
        "notification_id": task.get("notification_id"),
    }

    save_state(state)
    return True, f"Marked as **{action}**."