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

load_dotenv(Path(__file__).resolve().parent.parent / ".env")
DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

# storing queued DMs from dc_script polling
PENDING_DIR = Path("queue/pending")
PROCESSING_DIR = Path("queue/processing")
DONE_DIR = Path("queue/done")
FAILED_DIR = Path("queue/failed")

for d in [PENDING_DIR, PROCESSING_DIR, DONE_DIR, FAILED_DIR]:
    d.mkdir(parents=True, exist_ok=True)

class TaskBot(discord.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.views_registered_for_message_ids = set()
        self.bg_task = None


    # on each start (TODO: switch to on reconnect?), render all valid tasks and buttons
    async def setup_hook(self):
        await self.render_persistent_views()
        print("starting bg task")
        if self.bg_task is None or self.bg_task.done():
            self.bg_task = asyncio.create_task(self.process_queue())


    # render function; can also be used in on_resume() or on_ready()
    async def render_persistent_views(self):
        print("setup_hook start")
        state = load_state()

        for task_key, task in state.items():
            message_id = task.get("discord_message_id")
            if message_id and message_id not in self.views_registered_for_message_ids:
                self.add_view(TaskStatusView(task_key, status=task.get("status")), message_id=message_id)
                print("added view for", task_key, message_id)
                self.views_registered_for_message_ids.add(message_id)


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

                    if job.get("discord_user_id") is None:
                        print("dropping invalid job with missing discord_user_id:", job, flush=True)
                        processing_path.rename(DONE_DIR / processing_path.name)
                        continue

                    # sending DM
                    if job["type"] == "send_task_dm":
                        await self.send_task_dm(
                                discord_user_id=job["discord_user_id"],
                                text=job["text"],
                                task_key=job["task_key"],
                        )
                    elif job["type"] == "send_task_followup_dm":
                        await self.send_task_followup_dm(
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
        # redundant block; filtered out in process_queue
        if discord_user_id is None:
                print("send_task_dm: missing discord_user_id for", task_key, flush=True)
                return None
    
        user = await self.fetch_user(discord_user_id)
        view = TaskStatusView(task_key)
        msg = await user.send(view=view)

        state = load_state()
        if task_key not in state:
                state[task_key] = {}

        # using only newest msg to render buttons
        previous_message_id = state[task_key].get("discord_message_id")
        state[task_key].setdefault("previous_message_ids", [])
        if previous_message_id and previous_message_id != msg.id:
            state[task_key]["previous_message_ids"].append(previous_message_id)

        state[task_key]["discord_message_id"] = msg.id
        state[task_key]["discord_user_id"] = discord_user_id
        state[task_key]["discord_sent_at"] = utc_now_iso()
        state[task_key]["text"] = text
        save_state(state)

        self.add_view(TaskStatusView(task_key, status=state[task_key].get("status")), message_id=msg.id)
        self.views_registered_for_message_ids.add(msg.id)

        return msg.id
    
    
    async def send_task_followup_dm(self, discord_user_id: int, text: str, task_key: str):
        if discord_user_id is None:
                return None

        state = load_state()
        task = state.get(task_key, {})
        original_message_id = task.get("discord_message_id")
        if not original_message_id:
                return await self.send_task_dm(discord_user_id, text, task_key)

        user = self.get_user(discord_user_id) or await self.fetch_user(discord_user_id)
        channel = user.dm_channel or await user.create_dm()

        subject = task.get("subject", "Task")
        deadline = task.get("deadline", "")
        status = task.get("status", "pending")

        reminder = f"Reminder: {subject}\nStatus: {status}"
        if deadline:
                reminder += f"\nDeadline: {deadline}"

        try:
                original_msg = await channel.fetch_message(original_message_id)
                await channel.send(reminder, reference=original_msg)
        except discord.NotFound:
                await channel.send(reminder)
        return None


def build_bot():
    intents = discord.Intents.default()
    return TaskBot(intents=intents)


# persistent run
def main():
    bot = build_bot()
    bot.run(DISCORD_BOT_TOKEN, reconnect=True)


if __name__ == "__main__":
    main()