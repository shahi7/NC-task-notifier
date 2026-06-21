# TODO: temp; to delete
import discord
from dc_bot_ui import TaskStatusView
from helpers import load_state, save_state, utc_now_iso

# single session DM send
class DMClient(discord.Client):
    def __init__(self, text: str, discord_user_id: int, task_key: str, **kwargs):
        super().__init__(**kwargs)
        self.text = text
        self.discord_user_id = discord_user_id
        self.task_key = task_key          

    async def on_ready(self):
        print(f"9dc: logged into Discord as {self.user}")
        try:
            user = await self.fetch_user(self.discord_user_id)
            print(f"9dd: fetched discord user = {user} ({user.id})")

            view = TaskStatusView(self.task_key)   
            print(f"9de: view children = {len(view.children)}")  # should be 2

            await user.send(self.text, view=view)  
            print("9df: discord DM sent with buttons")
        finally:
            await self.close()

# first persistent bot attempt; currently unused
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