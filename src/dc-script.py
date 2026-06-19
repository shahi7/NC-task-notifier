"""
Polls NextCloud for new task notifications and queues them in local cache
"""
# TODO: run in background (cron/systemd)
# TODO: implement update_nextcloud
#!/usr/bin/env python3
from datetime import datetime, timedelta, timezone
import os
import requests
import asyncio
import discord
import json
from dotenv import load_dotenv
from helpers import cleanup_old_cache_files, parse_nc_datetime, format_notification_text, load_cache, save_cache
from dc_bot_client import DMClient


print("1: script started")

# use env vars
load_dotenv()

# Now read from environment
NEXTCLOUD_URL = os.getenv("NEXTCLOUD_URL")
NEXTCLOUD_USER = os.getenv("NEXTCLOUD_USER")
NEXTCLOUD_PASS = os.getenv("NEXTCLOUD_PASS")
SIGNAL_URL = os.getenv("SIGNAL_URL")
SIGNAL_SENDER = os.getenv("SIGNAL_SENDER")

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

USER_MAP_SIGNAL = json.loads(os.getenv("USER_MAP_SIGNAL", "{}"))
USER_MAP_DC = json.loads(os.getenv("USER_MAP_DC", "{}"))

print("2: config loaded")
print("2b: USER_MAP keys =", list(USER_MAP_SIGNAL.keys()))


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
    except:
        print("8x: request failed =", repr(e))
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


def send_signal(text, recipients):
    print("9: entering send_signal")
    print("9a: recipients =", recipients)
    print("9b: message =", text)
    payload = {
        "message": text,
        "number": SIGNAL_SENDER,
        "recipients": recipients,
    }
    print("9c: payload =", payload)
    r = requests.post(SIGNAL_URL, json=payload, timeout=20)
    print("9d: signal response status =", r.status_code)
    print("9e: signal response text =", r.text[:1000])
    r.raise_for_status()
    print("9f: signal send succeeded")


async def send_discord(text: str, discord_user_id: int, task_key: str):  
    intents = discord.Intents.default()
    client = DMClient(text=text, discord_user_id=discord_user_id, task_key=task_key, intents=intents)
    await client.start(DISCORD_BOT_TOKEN)

"""
TODO: replace send_discord() -> handoff layer for persistent TaskBot
QUEUE_DIR = Path("queue/pending")
QUEUE_DIR.mkdir(parents=True, exist_ok=True)

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
"""

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
        if user not in USER_MAP_SIGNAL and user not in USER_MAP_DC:
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

        # send notif via signal + discord
        if user in USER_MAP_SIGNAL: send_signal(text, USER_MAP_SIGNAL[user])
        if user in USER_MAP_DC: asyncio.run(send_discord(text, USER_MAP_DC[user], str(notification_id)))
        # TODO: replace with - enqueue_discord_dm(text, USER_MAP_DC[user], str(notification_id))
        sent_ids.add(notification_id)
        print("12e: added notification_id to sent_ids =", notification_id)


    save_cache(sent_ids)
    print("13: main finished")


if __name__ == "__main__":
    print("14: calling main()")
    main()
    print("15: script finished")