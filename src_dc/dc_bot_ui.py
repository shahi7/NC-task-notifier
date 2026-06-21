"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
import discord
from src.update_nextcloud import update_nextcloud_task

class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, disabled: bool = False, chosen_action: str | None = None):
        super().__init__(timeout=None)
        self.add_item(TaskButton(task_key, "working", disabled=disabled, chosen_action=chosen_action))
        self.add_item(TaskButton(task_key, "done", disabled=disabled, chosen_action=chosen_action))


class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str, disabled: bool = False, chosen_action: str | None = None):
        if action == "working":
            label = "Accept"
            style = discord.ButtonStyle.primary
        else:
            label = "Mark Completed"
            style = discord.ButtonStyle.success

        if disabled:
            if chosen_action == action:
                label = "In-Progress" if action == "working" else "Success!"
            style = discord.ButtonStyle.secondary

        super().__init__(
            label=label,
            style=style,
            custom_id=f"task:{task_key}:{action}",
            disabled=disabled,
        )

    async def callback(self, interaction: discord.Interaction):
        _, task_key, action = self.custom_id.split(":")
        ok, message = update_nextcloud_task(task_key, action)
        if not ok:
            await interaction.response.send_message(message, ephemeral=True)
            return

        # update buttons on response
        if action == "working":
            self.label = "In-Progress"
        else:
            self.label = "Success!"

        self.style = discord.ButtonStyle.secondary

        for item in self.view.children:
            item.disabled = True

        await interaction.response.edit_message(view=self.view)
        await interaction.followup.send(message, ephemeral=True)