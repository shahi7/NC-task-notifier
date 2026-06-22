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
from helpers import cleanup_old_cache_files, parse_nc_datetime, format_notification_text, load_cache, save_cache
QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)


print("1: script started")

# use env vars
load_dotenv()

# Now read from environment
NEXTCLOUD_URL = os.getenv("NEXTCLOUD_URL")
NEXTCLOUD_USER = os.getenv("NEXTCLOUD_USER")
NEXTCLOUD_PASS = os.getenv("NEXTCLOUD_PASS")

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

USER_MAP_DC = json.loads(os.getenv("USER_MAP_DC", "{}"))

print("2: config loaded")
print("2b: USER_MAP keys =", list(USER_MAP_DC.keys()))


def fetch_notifications():
    now = datetime.now(timezone.utc).isoformat()
    test_user = "azshahid2013@gmail.com"  

    return [
        {
            "notification_id": "test-1",
            "user": test_user,
            "datetime": now,
            "subject": "Offline test task 1",
            "message": (
                "Calendar: test\n"
                "Description: verify Accept button flow\n"
                "Date: 2026-06-21 - 10:00"
            ),
            "link": "",
        },
        {
            "notification_id": "test-2",
            "user": test_user,
            "datetime": now,
            "subject": "Offline test task 2",
            "message": (
                "Calendar: test\n"
                "Description: verify Mark Completed flow\n"
                "Date: 2026-06-21 - 11:00"
            ),
            "link": "",
        },
        {
            "notification_id": "test-3",
            "user": test_user,
            "datetime": now,
            "subject": "Offline test task 3",
            "message": (
                "Calendar: work\n"
                "Description: verify multiple queued DMs\n"
                "Date: 2026-06-21 - 12:00"
            ),
            "link": "https://example.com/task/3",
        },
        {
            "notification_id": "test-4",
            "user": test_user,
            "datetime": now,
            "subject": "Offline test task 4",
            "message": (
                "Calendar: personal\n"
                "Description: verify state save per task\n"
                "Date: 2026-06-21 - 13:00"
            ),
            "link": "",
        },
        {
            "notification_id": "test-5",
            "user": test_user,
            "datetime": now,
            "subject": "Offline test task 5",
            "message": (
                "Calendar: errands\n"
                "Description: verify delegator Signal notify\n"
                "Date: 2026-06-21 - 14:00"
            ),
            "link": "",
        },
    ]


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

        text = format_notification_text(subject, message, notification_id)
        if link:
                text += f"\n{link}"

        print("12d: final text =", text)

        # send notif via discord
        if user in USER_MAP_DC: enqueue_discord_dm(text, USER_MAP_DC[user], str(notification_id))
        sent_ids.add(notification_id)
        print("12e: added notification_id to sent_ids =", notification_id)


    save_cache(sent_ids)
    print("13: main finished")


if __name__ == "__main__":
    print("14: calling main()")
    main()
    print("15: script finished")