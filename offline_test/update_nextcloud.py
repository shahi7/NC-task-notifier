"""
Updates task state locally for offline testing.
Temporary stub replacement for NextCloud server calls.
"""

from helpers import load_state, utc_now_iso, save_state

def update_nextcloud_task(task_key: str, action: str):
    state = load_state()
    task = state.get(task_key)
    if not task:
        return False, f"Unknown task key: {task_key}"

    task["workflow_status"] = action
    task["workflow_updated_at"] = utc_now_iso()
    task["nextcloud_update"] = {
        "pending": False,
        "offline_test": True,
        "action": action,
    }

    save_state(state)
    return True, f"Marked as **{action}** (offline test)."