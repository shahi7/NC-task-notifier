"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
# TODO: add undo option
import discord # type: ignore
from offline_test.helpers import load_state
from update_nextcloud import update_nextcloud_task
from offline_test.helpers import notify_delegator

class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, disabled: bool = False, chosen_action: str | None = None):
        super().__init__(timeout=None)
        self.add_item(TaskButton(task_key, "working", disabled=disabled, chosen_action=chosen_action))
        self.add_item(TaskButton(task_key, "done", disabled=disabled, chosen_action=chosen_action))


class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str, disabled: bool = False, chosen_action: str | None = None):
        label, style = self.button_state(action, task_key, disabled, chosen_action)

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

        updated_view = TaskStatusView(task_key, disabled=True, chosen_action=action)
        await interaction.response.edit_message(view=updated_view)
        await interaction.followup.send(message, ephemeral=True)
        notify_delegator(action, task_key)


    def button_state(self, action: str, task_key: str, disabled: bool = False, chosen_action: str | None = None):
        state = load_state()
       
        if action == "working":
                state[task_key]["status"] = "working"
                label = "Accept"
                style = discord.ButtonStyle.primary
        else:
                state[task_key]["status"] = "done"
                label = "Mark Completed"
                style = discord.ButtonStyle.success

        # for interactions
        if disabled:
                if chosen_action == action:
                        label = "In-Progress" if action == "working" else "Success!"
                        style = discord.ButtonStyle.secondary
                # grey out both buttons if task completed
                elif chosen_action == "done" and action == "working":
                        label = "In-Progress"
                        style = discord.ButtonStyle.secondary

        # for cancellations
        if state[task_key]["status"] == "pending" and action == "working": # second condition not needed?
                state[task_key]["status"] = "pending"
                label = "Accept"
                style = discord.ButtonStyle.primary
        elif state[task_key]["status"] == "pending" and action == "done":
                state[task_key]["status"] = "pending"
                label = "Mark Completed"
                style = discord.ButtonStyle.success

        return label, style