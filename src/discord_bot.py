#!/usr/bin/env python3
import os
import discord
from dotenv import load_dotenv
from src.helpers import load_state, utc_now_iso, save_state
from src.update_nextcloud import update_nextcloud_task

load_dotenv()

DISCORD_BOT_TOKEN = os.getenv("DISCORD_BOT_TOKEN")
NEXTCLOUD_BASE_URL = os.getenv("NEXTCLOUD_BASE_URL", "").rstrip("/")
NEXTCLOUD_USER = os.getenv("NEXTCLOUD_USER")
NEXTCLOUD_PASS = os.getenv("NEXTCLOUD_PASS")

class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str):
        super().__init__(timeout=None)
        self.add_item(TaskButton(task_key, "working"))
        self.add_item(TaskButton(task_key, "done"))


class DMClient(discord.Client):
    def __init__(self, text: str, discord_user_id: int, task_key: str, **kwargs):
        super().__init__(**kwargs)
        self.text = text
        self.discord_user_id = discord_user_id
        self.task_key = task_key            # <-- added

    async def on_ready(self):
        print(f"9dc: logged into Discord as {self.user}")
        try:
            user = await self.fetch_user(self.discord_user_id)
            print(f"9dd: fetched discord user = {user} ({user.id})")

            view = TaskStatusView(self.task_key)    # <-- create view
            print(f"9de: view children = {len(view.children)}")  # should be 2

            await user.send(self.text, view=view)   # <-- pass view here
            print("9df: discord DM sent with buttons")
        finally:
            await self.close()

# dynamic button subclass. unique custom_id per task + action
class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str):
        if action == "working":
            label = "Accept (In-Progress)"
            style = discord.ButtonStyle.primary
        else:
            label = "Mark Completed"
            style = discord.ButtonStyle.success

        super().__init__(
            label=label,
            style=style,
            custom_id=f"task:{task_key}:{action}",  # unique per task
        )

    async def callback(self, interaction: discord.Interaction):
        parts = self.custom_id.split(":")
        task_key = parts[1]
        action = parts[2]
        _, message = update_nextcloud_task(task_key, action)
        await interaction.response.send_message(message, ephemeral=True)


class TaskBot(discord.Client):
    async def setup_hook(self):
        state = load_state()
        for task_key in state.keys():
            self.add_view(TaskStatusView(task_key))
        print(f"setup_hook: registered {len(state)} persistent views")

    async def on_ready(self):
        print(f"Logged in as {self.user} ({self.user.id})")

    async def send_task_dm(self, discord_user_id: int, text: str, task_key: str):
        user = await self.fetch_user(discord_user_id)
        view = TaskStatusView(task_key)

        print(f"send_task_dm: view children = {len(view.children)}")  # should print 2

        msg = await user.send(text, view=view)

        state = load_state()
        if task_key not in state:
            state[task_key] = {}
        state[task_key]["discord_message_id"] = msg.id
        state[task_key]["discord_user_id"] = discord_user_id
        state[task_key]["discord_sent_at"] = utc_now_iso()
        save_state(state)

        return msg.id

def main():
    intents = discord.Intents.default()
    client = TaskBot(intents=intents)
    client.run(DISCORD_BOT_TOKEN)


if __name__ == "__main__":
    main()