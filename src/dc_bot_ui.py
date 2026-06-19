import discord
from update_nextcloud import update_nextcloud_task


class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str):
        super().__init__(timeout=None)
        self.add_item(TaskButton(task_key, "working"))
        self.add_item(TaskButton(task_key, "done"))


class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str):
        if action == "working":
            label = "Accept"
            style = discord.ButtonStyle.primary
        else:
            label = "Mark Completed"
            style = discord.ButtonStyle.success

        super().__init__(
            label=label,
            style=style,
            custom_id=f"task:{task_key}:{action}",
        )

    async def callback(self, interaction: discord.Interaction):
        _, task_key, action = self.custom_id.split(":")
        ok, message = update_nextcloud_task(task_key, action)

        if action == "working":
            self.label = "In-Progress"
        else:
            self.label = "Success!"

        self.style = discord.ButtonStyle.secondary

        for item in self.view.children:
            item.disabled = True

        await interaction.response.edit_message(view=self.view)
        await interaction.followup.send(message, ephemeral=True)