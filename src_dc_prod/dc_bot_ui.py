"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
# TODO: progress bar, stale buttons, clear cache (queue + buttons), reflect updates from NC end (automatic?)
import asyncio
import discord # type: ignore
from helpers import load_state
from update_nextcloud import update_nextcloud_task
from helpers import notify_delegator


class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, status: str = "pending", percentage: int = 0):
        super().__init__(timeout=None)

        state = load_state()
        task = state.get(str(task_key), {})
        if percentage is None:
            percentage = int(task.get("percent_complete", 0) or 0)

        # rendering labels + buttons based on current status of task
        if status in ("pending", "cancelled"):
            self.add_item(TaskButton(task_key, "working", "Accept Task", discord.ButtonStyle.primary))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
        elif status == "working":
            self.add_item(TaskButton(task_key, "working", "Cancel Task", discord.ButtonStyle.danger))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
        elif status == "done":
            self.add_item(TaskButton(task_key, "done", "Completed! Click to undo", discord.ButtonStyle.secondary))
        embed = discord.Embed(
                title="", 
                description=render_progress_bar(percentage),
                color=discord.Color.blue()
        )
        self.add_item(Completion(task_key, "working"))


class TaskButton(discord.ui.Button):
    def __init__(self, task_key, action, label, style):
        super().__init__(
                label=label,
                style=style,
                custom_id=f"task:{task_key}:{action}"
        )

    async def callback(self, interaction: discord.Interaction):
        print("before defer")
        # avoid hang from update_nextcloud_task
        await interaction.response.defer()
        print("after defer")
        state = load_state()

        _, task_key, action = self.custom_id.split(":")
        task = state.get(task_key)
        if not isinstance(task, dict):
            await interaction.followup.send("Task not found.", ephemeral=True)
            return

        current = task.get("status", "pending")

        # updating status 
        if action == "working":
            if current in ("pending", "cancelled"):
                new_status = "working"
            else:
                new_status = "cancelled"
        else:  # done
            if current == "done":
                new_status = "working"
            else:
                new_status = "done"
        print(f"new status: {new_status}\n")

        # view renders before expensive nextcloud operation
        updated_view = TaskStatusView(task_key, status=new_status)
        await interaction.edit_original_response(view=updated_view)

        # state save (w/ new status) happens in update_nextcloud_task
        try:
                _, message = await asyncio.to_thread(update_nextcloud_task, task_key, new_status)
        except Exception as e:
                await interaction.followup.send(f"Nextcloud update failed: {e}", ephemeral=True)
                return
        
        await interaction.followup.send(message, ephemeral=True)

        print("updating view\n\n")
        await asyncio.to_thread(notify_delegator, action, task_key)


class Completion(discord.ui.Select):
    def __init__(self, task_key, status):
        # set up the menu options
        self.task_key = task_key
        self.status = status

        options = [
            discord.SelectOption(label="0% Completion", description="0% Completion"),
            discord.SelectOption(label="50% Completion", description="50% Completion"),
            discord.SelectOption(label="75% Completion", description="75% Completion"),
        ]

        super().__init__(
            placeholder="% Completed",
            min_values=1,
            max_values=1,
            options=options,
        )

    async def callback(self, interaction: discord.Interaction):
        percentage = self.values[0].split("%")[0]
        updated_view = TaskStatusView(self.task_key, self.status, percentage)

        await interaction.response.edit_message(
            content=render_progress_bar(percentage),
            view=updated_view,
        )


def render_progress_bar(percent: int) -> str:
    filled = percent // 10
    empty = 10 - filled
    return f"[{'█' * filled}{'░' * empty}] {percent}%"