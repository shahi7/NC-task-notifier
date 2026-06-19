# TODO: should run in background
#!/usr/bin/env python3
import os
import discord
from dotenv import load_dotenv
from helpers import load_state
from dc_bot_ui import TaskStatusView
import asyncio
import json
from pathlib import Path

load_dotenv()
DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")

PENDING_DIR = Path("queue/pending")
PROCESSING_DIR = Path("queue/processing")
DONE_DIR = Path("queue/done")
FAILED_DIR = Path("queue/failed")

for d in [PENDING_DIR, PROCESSING_DIR, DONE_DIR, FAILED_DIR]:
    d.mkdir(parents=True, exist_ok=True)

class TaskBot(discord.Client):
    async def setup_hook(self):
        state = load_state()
        for task_key in state.keys():
            self.add_view(TaskStatusView(task_key))
        self.bg_task = asyncio.create_task(self.process_queue())

    async def process_queue(self):
        await self.wait_until_ready()
        while not self.is_closed():
            for path in PENDING_DIR.glob("*.json"):
                processing_path = PROCESSING_DIR / path.name
                try:
                    path.rename(processing_path)
                except FileNotFoundError:
                    continue

                try:
                    job = json.loads(processing_path.read_text())

                    if job["type"] == "send_task_dm":
                        await self.send_task_dm(
                            discord_user_id=job["discord_user_id"],
                            text=job["text"],
                            task_key=job["task_key"],
                        )

                    processing_path.rename(DONE_DIR / processing_path.name)

                except Exception:
                    processing_path.rename(FAILED_DIR / processing_path.name)

            await asyncio.sleep(2)


def build_bot():
    intents = discord.Intents.default()
    return TaskBot(intents=intents)


def main():
    bot = build_bot()
    bot.run(DISCORD_BOT_TOKEN)


if __name__ == "__main__":
    main()