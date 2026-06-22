"""
Persistent Discord bot for polling notification queue (updated by dc_script), sending DMs,
and dynamically updating UI 
"""
# TODO: run in background; systemd
#!/usr/bin/env python3
import os
import discord # type: ignore
from dotenv import load_dotenv # type: ignore
from helpers import load_state, save_state, utc_now_iso
from dc_bot_ui import TaskStatusView
import asyncio
import json
from pathlib import Path

load_dotenv()
DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

# storing queued DMs from dc_script polling
PENDING_DIR = Path("queue/pending")
PROCESSING_DIR = Path("queue/processing")
DONE_DIR = Path("queue/done")
FAILED_DIR = Path("queue/failed")

for d in [PENDING_DIR, PROCESSING_DIR, DONE_DIR, FAILED_DIR]:
    d.mkdir(parents=True, exist_ok=True)

class TaskBot(discord.Client):
    async def setup_hook(self):
        print("setup_hook start")
        # state = load_state()
        # for task_key in state.keys():
        #    self.add_view(TaskStatusView(task_key))
        # polling queue for updates 
        state = load_state()
        print("loaded state", list(state.keys()))

        for task_key, task in state.items():
            print("loaded state", list(state.keys()))
            message_id = task.get("discord_message_id")
            if message_id:
                self.add_view(TaskStatusView(task_key, status=task.get("status")), message_id=message_id)
                print("added view for", task_key, message_id)

        print("starting bg task")
        self.bg_task = asyncio.create_task(self.process_queue())

    # poll queue
    async def process_queue(self):
        await self.wait_until_ready()
        while not self.is_closed():
            for path in list(PENDING_DIR.glob("*.json")) + list(FAILED_DIR.glob("*.json")):
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
                            discord_user_id=job["discord_user_id"],
                            text=job["text"],
                            task_key=job["task_key"],
                        )

                    # de-queueing
                    processing_path.rename(DONE_DIR / processing_path.name)

                except Exception as e:
                    print("queue job failed:", repr(e))
                    processing_path.rename(FAILED_DIR / processing_path.name)

            await asyncio.sleep(2)

    # set UI
    async def send_task_dm(self, discord_user_id: int, text: str, task_key: str):
        user = await self.fetch_user(discord_user_id)
        view = TaskStatusView(task_key)
        msg = await user.send(text, view=view)

        state = load_state()
        if task_key not in state:
                state[task_key] = {}
        state[task_key]["discord_message_id"] = msg.id
        state[task_key]["discord_user_id"] = discord_user_id
        state[task_key]["discord_sent_at"] = utc_now_iso()
        state[task_key]["text"] = text
        save_state(state)

        return msg.id


def build_bot():
    intents = discord.Intents.default()
    return TaskBot(intents=intents)

# persistent run
def main():
    bot = build_bot()
    bot.run(DISCORD_BOT_TOKEN, reconnect=True)

if __name__ == "__main__":
    main()