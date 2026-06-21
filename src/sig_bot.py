"""
Persistent bot for polling Signal notification queue (updated by dc_script), sending DMs,
and dynamically updating UI 
"""
# TODO: run in background; systemd
# TODO: support multiple recipients?
#!/usr/bin/env python3
from datetime import time
import os
from dotenv import load_dotenv
from helpers import load_state, save_state, utc_now_iso
import asyncio
import json
import requests
from pathlib import Path
from update_nextcloud import update_nextcloud_task

load_dotenv()


SIGNAL_SENDER = os.getenv("SIGNAL_URL_GET")
SIGNAL_URL_GET = os.getenv("SIGNAL_SENDER")
SIGNAL_URL = os.getenv("SIGNAL_URL")

# storing queued DMs from dc_script polling
PENDING_DIR = Path("queue/pending")
PROCESSING_DIR = Path("queue/processing")
DONE_DIR = Path("queue/done")
FAILED_DIR = Path("queue/failed")

for d in [PENDING_DIR, PROCESSING_DIR, DONE_DIR, FAILED_DIR]:
    d.mkdir(parents=True, exist_ok=True)

class TaskBot():
    # poll queue
    async def process_queue(self):
        await self.wait_until_ready()
        while not self.is_closed():
            for path in PENDING_DIR.glob("*.json"):
                processing_path = PROCESSING_DIR/path.name
                try:
                    path.rename(processing_path)
                except FileNotFoundError:
                    continue

                # processing message/queue item
                try:
                    job = json.loads(processing_path.read_text())

                    # sending DM
                    if job["type"] == "send_task_dm":
                        await self.send_task_dm(
                            signal_num=job["signal_num"],
                            text=job["text"],
                            task_key=job["task_key"],
                        )

                    # de-queueing
                    processing_path.rename(DONE_DIR / processing_path.name)

                except Exception:
                    processing_path.rename(FAILED_DIR / processing_path.name)

            await asyncio.sleep(2)

    # set UI
    async def send_task_dm(self, signal_num: int, text: str, task_key: str):
        payload = {
                "message": f"Task #: {task_key}\n" + text,
                "number": SIGNAL_SENDER,
                "recipients": [signal_num],
        }
        print("9c: payload =", payload)
        r = requests.post(SIGNAL_URL, json=payload, timeout=20)
        r.raise_for_status()

        state = load_state()
        if str(task_key) not in state:
            state[task_key] = {}
        state[str(task_key)]["signal_num"] = str(signal_num)
        state[str(task_key)]["signal_sent_at"] = utc_now_iso()

        # accounting for multiple tasks per person; keep tasks identifiable via text
        if "signal_index" not in state:
            state["signal_index"] = {}
        state["signal_index"][str(signal_num)] = task_key
            
        save_state(state)


    async def callback(self):
        # read messages for "done" and "accept"
        state = load_state()

        r = requests.get(f"{SIGNAL_URL_GET}{SIGNAL_SENDER}", timeout=20, max_messages=50)
        r.raise_for_status()
        data = r.json()

        # O(n); assuming not many messages are received at a time
        for envelope in data:
            msg = (
                envelope.get("envelope", {})
                .get("dataMessage", {})
            )
            msg_stripped = (    
                msg.get("message", "")
                .strip()
                .lower()
            )

            # valid msgs are "done"/"accept" and are a reply to a task (quote)
            if msg_stripped not in {"done", "accept"} or not (msg.get("quote") and msg.get("quote").get("text")): 
                continue

            task = msg.get("quote").get("text")
            action = "done" if msg == "done" else "working"

            # use sender, quote.id and recepient to find task_key of task that was interacted with
            task_key = task.split("\n")[0].split("#: ")[1]
            _, message = update_nextcloud_task(task_key, action)
            print(f"{task_key}: {message}")
        
        state[str(task_key)]["signal_num"] = SIGNAL_SENDER
        state[str(task_key)]["signal_sent_at"] = utc_now_iso()
        save_state(state)


    # TODO: implement for signal
    # better for dynamic updates; renders single generic task view
    def run_bg(self):
        while True:
            try:
                self.process_queue()
            except Exception as e:
                print(f"process_queue failed: {e}")

            try:
                self.callback()
            except Exception as e:
                print(f"process_inbound_replies failed: {e}")

            time.sleep(2)


# persistent run
def main():
    bot = TaskBot()
    bot.run_bg()


if __name__ == "__main__":
    main()