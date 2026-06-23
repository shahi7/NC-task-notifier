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
    def __init__(self, task_key: str, status: str = "pending"):
        super().__init__(timeout=None)

        # rendering labels + buttons based on current status of task
        if status in ("pending", "cancelled"):
            self.add_item(TaskButton(task_key, "working", "Accept Task", discord.ButtonStyle.primary))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
        elif status == "working":
            self.add_item(TaskButton(task_key, "working", "Cancel Task", discord.ButtonStyle.danger))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
        elif status == "done":
            self.add_item(TaskButton(task_key, "done", "Completed! Click to undo", discord.ButtonStyle.secondary))


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

        # state save (w/ new status) happens in update_nextcloud_task
        try:
                _, message = await asyncio.to_thread(update_nextcloud_task, task_key, new_status)
        except Exception as e:
                await interaction.followup.send(f"Nextcloud update failed: {e}", ephemeral=True)
                return

        print("updating view\n\n")
        updated_view = TaskStatusView(task_key, status=new_status)
        await interaction.edit_original_response(view=updated_view)
        await interaction.followup.send(message, ephemeral=True)
        await asyncio.to_thread(notify_delegator, action, task_key)