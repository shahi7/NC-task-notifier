"""
Periodically polls NextCloud for new task notifications and queues them in local cache
When a notification is found, starts up TaskBot (to send messages)
"""
# TODO: schedule in background (cron)
# TODO: notify delegator 
#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import uuid
import requests # type: ignore
import json
from dotenv import load_dotenv # type: ignore
from helpers import cleanup_old_cache_files, get_client, parse_nc_datetime, format_text_and_state, load_cache, save_cache, load_state, save_state, merge_task_into_event_uid
QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)
SYNC_TOKEN_FILE = Path("calendar_sync_token.txt")

print("1: script started")

# use env vars
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# Now read from environment
NEXTCLOUD_URL = os.getenv("NEXTCLOUD_URL")
NEXTCLOUD_USER = os.getenv("NEXTCLOUD_USER")
NEXTCLOUD_PASS = os.getenv("NEXTCLOUD_PASS")

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

USER_MAP_DC = json.loads(os.getenv("USER_MAP_DC", "{}"))

print("2: config loaded")
print("2b: USER_MAP keys =", list(USER_MAP_DC.keys()))


def load_sync_token():
    if not SYNC_TOKEN_FILE.exists():
        return None
    return SYNC_TOKEN_FILE.read_text().strip() or None


def save_sync_token(token):
    if token:
        SYNC_TOKEN_FILE.write_text(token)


def try_match_existing_event_uid(task_key: str):
    print("15: entering try_match_existing_event_uid")
    state = load_state()
    task = state.get(str(task_key))
    if not isinstance(task, dict):
        print("15a: task missing or invalid")
        return str(task_key)

    for existing_key, existing_task in state.items():
        # avoid trivial match to self
        if str(existing_key) == str(task_key):
            continue
        if not isinstance(existing_task, dict):
            continue

        # checking all locally stored values
        if (
            existing_task.get("subject", "").strip() == task.get("subject", "").strip()
            and existing_task.get("description", "").strip() == task.get("description", "").strip()
            and existing_task.get("deadline", "") == task.get("deadline", "")
            and existing_task.get("calendar_name", "").strip().lower() == task.get("calendar_name", "").strip().lower()
            and existing_task.get("event_uid", "").strip()
        ):
            print("15b: matched existing event_uid =", existing_task.get("event_uid"))
            task["event_uid"] = existing_task.get("event_uid")
            task["event_url"] = existing_task.get("event_url", "")
            save_state(state)

            final_task_key = merge_task_into_event_uid(str(task_key), str(existing_task.get("event_uid")))
            print("15c: final_task_key from existing match =", final_task_key)
            return final_task_key

    print("15d: no existing event_uid match found")
    return str(task_key)


# TODO: notifications for the SAME event should render as a single persistent message
# event_uid as key instead of task_key?
def try_pair_notification_to_event(task_key: str):
    print("16: entering try_pair_notification_to_event")
    state = load_state()
    task = state.get(str(task_key))
    if not isinstance(task, dict):
        print("16a: task missing or invalid")
        return str(task_key)

    calendar_name = (task.get("calendar_name") or "").strip().lower()
    object_id = str(task.get("object_id") or "")
    print("16b: calendar_name =", calendar_name)
    print("16c: object_id =", object_id)

    if not calendar_name:
        print("16d: no calendar_name, skipping")
        return str(task_key)
    
    # fast path: maybe this notification already belongs to an existing task
    # CalDAV requests more expensive
    local_match_key = try_match_existing_event_uid(str(task_key))
    if str(local_match_key) != str(task_key):
        print("16aa: paired using existing local event_uid")
        return str(local_match_key)

    # using sync tokens to find newly created/modified objects (events and TODOs)
    old_token = load_sync_token()
    print("16e: old_token =", old_token)

    with get_client() as client:
        principal = client.principal()
        calendar = next(
            (c for c in principal.calendars() if (c.name or "").strip().lower() == calendar_name),
            None,
        )
        if calendar is None:
            print("16f: calendar not found")
            return str(task_key)
        if not old_token:
            print("16g: no old token yet, saving initial token and skipping match")
            save_sync_token(calendar.get_sync_token())
            return str(task_key)
    
        # getting all new events (new since last sync)
        changes = calendar.objects_by_sync_token(sync_token=old_token)
        
        candidate = {}
        matched = False
        # finding best candidate with matching fields
        for event in list(changes.new) + list(changes.modified):
                vevent = event.vobject_instance.vevent
                # vtodo = event.vobject_instance.vtodo
                candidate = {
                        "uid": getattr(vevent, 'uid', None).value if getattr(vevent, 'uid', None) else "",
                        "summary": getattr(vevent, 'summary', None).value if getattr(vevent, 'summary', None) else "",
                        "description": getattr(vevent, 'description', None).value if getattr(vevent, 'description', None) else "",
                        "location": getattr(vevent, 'location', None).value if getattr(vevent, 'location', None) else "",
                        "deadline": getattr(vevent, 'dtstart', None).value if getattr(vevent, 'dtstart', None) else None
                }

                print("16h: candidate =", candidate)

                if (
                        candidate["summary"].strip() == task["subject"].strip()
                        and candidate["description"].strip() == task["description"].strip()
                        and str(candidate["deadline"])[:10] == task["deadline"] # date only, no time
                ):
                        task["event_uid"] = candidate["uid"]
                        task["event_url"] = str(getattr(event, "url", ""))
                        save_state(state)
                        matched = True
                        print("16j: matched candidate, saved event_uid =", candidate["uid"])
                        break

        # updating sync
        save_sync_token(getattr(changes, "sync_token", None))

    if not matched:
        print("No candidate found")
        return str(task_key)

    final_task_key = merge_task_into_event_uid(str(task_key), task["event_uid"])
    print("16k: final_task_key =", final_task_key)
    return final_task_key


def fetch_notifications():
    print("8: entering fetch_notifications")
    headers = {
        "OCS-APIRequest": "true",
        "Accept": "application/json",
        "User-Agent": "nc-discord/1.0 (+requests)",
        "Connection": "close",
    }
    print("8a: requesting", NEXTCLOUD_URL)
    # intermittent failures recorded; request retried upon cron rerun 
    try:
        r = requests.get(
                NEXTCLOUD_URL,
                headers=headers,
                auth=(NEXTCLOUD_USER, NEXTCLOUD_PASS),
                timeout=20,
        )
        print("8b: response status =", r.status_code)
        print("8c: raw response text =", r.text[:1000])
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        print("8x: request failed", repr(e))
        return []
    
    print("8d: parsed json top-level keys =", list(data.keys()))

    if "ocs" not in data:
        print("8e: missing 'ocs' in response")
        raise RuntimeError("Invalid OCS response")
    if data["ocs"]["meta"]["statuscode"] != 200:
        print("8f: bad OCS status =", data["ocs"]["meta"]["statuscode"])
        raise RuntimeError(f"Nextcloud returned status {data['ocs']['meta']['statuscode']}")

    print("8g: notifications count =", len(data["ocs"]["data"]))
    return data["ocs"]["data"]


# handoff layer for persistent TaskBot
def enqueue_discord_dm(text: str, discord_user_id: int, task_key: str):
    job = {
        "type": "send_task_dm",
        "discord_user_id": discord_user_id,
        "text": text,
        "task_key": task_key,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    tmp_path = QUEUE_DIR / f"{uuid.uuid4()}.tmp"
    final_path = QUEUE_DIR / f"{uuid.uuid4()}.json"

    tmp_path.write_text(json.dumps(job, indent=2))
    tmp_path.rename(final_path)


# polling for notifs
def main():
    print("10: entering main")
    cleanup_old_cache_files()

    sent_ids = load_cache()
    print("10a: sent_ids =", sent_ids)
    notifications = fetch_notifications()
    print("10b: fetched notifications =", len(notifications))
    cutoff = datetime.now(timezone.utc) - timedelta(days=1)
    print("10c: cutoff =", cutoff.isoformat())


    for n in notifications:
        print("11: raw notification =", n)
        notification_id = n.get("notification_id")
        user = n.get("user")
        dt = parse_nc_datetime(n.get("datetime"))

        print("notification =", n)
        print("11a: notification_id =", notification_id)
        print("11b: user =", user)
        print("11c: dt =", dt)

        if not notification_id or not user or not dt:
            print("11d: skipping because missing notification_id/user/dt")
            continue
        if dt < cutoff:
            print("11e: skipping because dt is older than cutoff")
            continue
        if notification_id in sent_ids:
            print("11f: skipping because already sent")
            continue
        if user not in USER_MAP_DC:
            print("11g: skipping because user not in USER_MAP")
            continue

        print("12: processing notification for user =", user)

        subject = (n.get("subject") or "Nextcloud notification").strip()
        message = (n.get("message") or "").strip()
        link = (n.get("link") or "").strip()

        print("12a: subject =", subject)
        print("12b: message =", message)
        print("12c: link =", link)

        object_id = n.get("object_id")
        object_type = n.get("object_type")
        text = format_text_and_state(subject, message, notification_id, object_id, object_type)
        state = load_state()
        if str(notification_id) in state:
            state[str(notification_id)]["text"] = text
            save_state(state)

        # attempt event_uid task key
        final_task_key = try_pair_notification_to_event(str(notification_id))

        if link:
                text += f"\n{link}"

        print("12d: final text =", text)

        # send notif via discord
        if user in USER_MAP_DC:
                enqueue_discord_dm(text, USER_MAP_DC[user], str(final_task_key))
        sent_ids.add(notification_id)
        print("12e: added notification_id to sent_ids =", notification_id)

    save_cache(sent_ids)
    print("13: main finished")


if __name__ == "__main__":
    print("14: calling main()")
    main()
    print("15: script finished")