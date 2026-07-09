"""
Persistent Discord bot for polling notification queue (updated by dc_script), sending DMs,
and dynamically updating UI 
"""
#!/usr/bin/env python3
import asyncio
import json
from pathlib import Path
import os
import discord # type: ignore
from vault import vault_get_user_map_dc, vault_put_user_map_dc, get_delegations_for_user
from dotenv import load_dotenv # type: ignore
from helpers import load_state, save_state, utc_now_iso, get_secret
from dc_bot_ui import TaskStatusView

load_dotenv(Path(__file__).resolve().parent / ".env")
DISCORD_BOT_TOKEN = get_secret("DISCORD_BOT_TOKEN")

# storing queued DMs from dc_script polling
DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
PENDING_DIR = DATA_DIR / "queue" / "pending"
PROCESSING_DIR = DATA_DIR / "queue" / "processing"
DONE_DIR = DATA_DIR / "queue" / "done"
FAILED_DIR = DATA_DIR / "queue" / "failed"

for d in [PENDING_DIR, PROCESSING_DIR, DONE_DIR, FAILED_DIR]:
    d.mkdir(parents=True, exist_ok=True)


# main bot class; renders view + sends DMs
class TaskBot(discord.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.views_registered_for_message_ids = set()
        self.bg_task = None
        self.tree = discord.app_commands.CommandTree(self)


    # on each start (TODO: switch to on reconnect?), render all valid tasks and buttons
    async def setup_hook(self):
        await self.tree.sync()
        await self.render_persistent_views()
        print("starting bg task")
        if self.bg_task is None or self.bg_task.done():
            self.bg_task = asyncio.create_task(self.process_queue())


    # render function; can also be used in on_resume() or on_ready() 
    async def render_persistent_views(self):
        print("setup_hook start")
        state = load_state()

        for task_key, task in state.items():
                discord_messages = task.get("discord_messages", {})
                for _, meta in discord_messages.items():
                        message_id = meta.get("message_id")
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
                    
                    if job.get("sleep_duration", ""):
                        n = int(job["sleep_duration"]) 
                        await asyncio.sleep(n)

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
                                update=job["updated"]
                        )

                    # de-queueing
                    processing_path.rename(DONE_DIR / processing_path.name)

                except Exception as e:
                    # exponential increase to sleep time between retries 
                    if not job.get("sleep_duration", ""): 
                         job["sleep_duration"] = 1
                    else:
                         job["sleep_duration"] = job["sleep_duration"]**2

                    print("queue job failed:", repr(e))
                    processing_path.write_text(json.dumps(job, indent=2))
                    processing_path.rename(FAILED_DIR / processing_path.name)

            await asyncio.sleep(2)

    # set UI
    async def send_task_dm(self, discord_user_id: int, text: str, task_key: str):
        # redundant block; filtered out in process_queue
        if discord_user_id is None:
                print("send_task_dm: missing discord_user_id for", task_key, flush=True)
                return None
        
        state = load_state()
        if task_key not in state:
                state[task_key] = {}
    
        user = await self.fetch_user(discord_user_id)
        view = TaskStatusView(task_key)
        msg = await user.send(text, view=view)

        task = state.get(task_key, {})
        task.setdefault("discord_messages", {})
        task["discord_messages"][str(discord_user_id)] = {
                "message_id": msg.id,
                "sent_at": utc_now_iso(),
        }
        # task["text"] = text
        state[task_key] = task
        save_state(state)

        self.add_view(TaskStatusView(task_key, status=state[task_key].get("status")), message_id=msg.id)
        self.views_registered_for_message_ids.add(msg.id)

        return msg.id
    
    
    async def send_task_followup_dm(self, discord_user_id: int, text: str, task_key: str, update: dict):
        if discord_user_id is None:
                return None

        state = load_state()
        task = state.get(task_key, {})
        # if task info was updated, edit original message
        new_text = ""
        if update:
            subject = str(task.get("subject", "")).strip() or "Nextcloud Task"
            description = str(task.get("description", "")).strip() if task.get("description") else ""
            location = str(task.get("location", "")).strip()
            deadline_text = task.get("deadline", "").split("T")[0]
            parts = [subject]
            if description:
                parts.append(f"Description: {description}")
            if location:
                parts.append(f"Location: {location}")
            if deadline_text:
                parts.append(f"Deadline: {deadline_text}")
            new_text = "\n".join(parts)
            task["text"] = new_text

        discord_user_id = discord_user_id
        original_message_id = task.get("discord_messages", {}).get(str(discord_user_id), {}).get("message_id", "")
        
        user = self.get_user(discord_user_id) or await self.fetch_user(discord_user_id)
        channel = user.dm_channel or await user.create_dm()

        if not original_message_id:
                print("original message not found")
                await channel.send(text)
                return None
        # update msg if update
        elif new_text:
                original_msg = await channel.fetch_message(original_message_id)
                await original_msg.edit(content=new_text)

        try:
                original_msg = await channel.fetch_message(original_message_id)
                await channel.send(text, reference=original_msg)
        except discord.NotFound:
                await channel.send(text)
        return None


def build_bot():
    intents = discord.Intents.default()
    return TaskBot(intents=intents)

bot = build_bot()

# slash command for adding new assignees
@bot.tree.command(name="add_user", description="Add or update a Name -> Discord user mapping")
@discord.app_commands.describe(
    name="Assignee name",
    user="Discord username of new assignee",
    delegation_id="Delegation to update (optional; only needed if you manage multiple)",
)
async def add_user(
    interaction: discord.Interaction,
    name: str,
    user: discord.User,
    delegation_id: str | None = None,
):
    allowed = get_delegations_for_user(interaction.user.id)

    if not allowed:
        await interaction.response.send_message("Not allowed.", ephemeral=True)
        return

    if delegation_id is None:
        if len(allowed) == 1:
            delegation_id = str(allowed[0]["id"])
        else:
            await interaction.response.send_message(
                "You manage multiple delegations. Please provide delegation_id.",
                ephemeral=True,
            )
            return

    if not any(str(d.get("id")) == delegation_id for d in allowed):
        await interaction.response.send_message("Not allowed for that delegation.", ephemeral=True)
        return

    cleaned_name = name.strip().lower()
    cleaned_discord_id = str(user.id)

    if not cleaned_name:
        await interaction.response.send_message("Name cannot be empty.", ephemeral=True)
        return
    if not cleaned_discord_id.isdigit():
        await interaction.response.send_message("Discord ID must be numeric.", ephemeral=True)
        return

    current = vault_get_user_map_dc(delegation_id)
    current[cleaned_name] = cleaned_discord_id
    vault_put_user_map_dc(delegation_id, current)

    await interaction.response.send_message(
        f"Saved mapping: {cleaned_name} -> {cleaned_discord_id}",
        ephemeral=True,
    )


# persistent run
def main():
    bot.run(DISCORD_BOT_TOKEN, reconnect=True)


if __name__ == "__main__":
    main()