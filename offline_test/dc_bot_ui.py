"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
# TODO: retry failed, progress bar, stale buttons, clear cache (queue), reflect updates
import json
from pathlib import Path
import uuid
import discord # type: ignore
from helpers import load_state
from update_nextcloud import update_nextcloud_task
from helpers import notify_delegator

QUEUE_DIR = Path("buttons")

class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, label_and_id, clicked: bool = False, chosen_action: str | None = None, ):
        super().__init__(timeout=None)
        state = load_state()

        # dynamically create buttons; skip old buttons (for now)
        for label, button_id in label_and_id:
            if state[task_key]["status"] != "done" and label == "working":
                  continue
            self.add_item(TaskButton(label=label, custom_id=button_id))
        
              
class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str, clicked: bool = False, chosen_action: str | None = None):
        label, style = self.button_state(action, task_key, clicked, chosen_action)

        super().__init__(
                label=label,
                style=style,
                custom_id=f"task:{task_key}:{action}",
                # disabled=disabled,
        )

    async def callback(self, interaction: discord.Interaction):
        # button_id = self.custom_id
        _, task_key, action = self.custom_id.split(":")
        ok, message = update_nextcloud_task(task_key, action)
        if not ok:
                await interaction.response.send_message(message, ephemeral=True)
                return

        updated_view = TaskStatusView(task_key, clicked=True, chosen_action=action)
        await interaction.response.edit_message(view=updated_view)
        await interaction.followup.send(message, ephemeral=True)
        notify_delegator(action, task_key)


    def button_state(self, action: str, task_key: str, clicked: bool = False, chosen_action: str | None = None):
        state = load_state()
       
        if action == "working":
                label = "Accept"
                style = discord.ButtonStyle.primary
        else:
                label = "Mark Completed"
                style = discord.ButtonStyle.success

        # for interactions
        if clicked and state[task_key]["status"] == "pending":
                if chosen_action == action:
                        state[task_key]["status"] = "working"
                        label = "In-Progress" if action == "working" else "Completed!\nClick to undo"
                        style = discord.ButtonStyle.secondary

        # for cancellations
        if state[task_key]["status"] == "working" and action == "working": # second condition not needed?
                state[task_key]["status"] = "pending"
                label = "Accept"
                style = discord.ButtonStyle.primary
        elif state[task_key]["status"] == "done" and action == "done":
                state[task_key]["status"] = "pending"
                label = "Mark Completed"
                style = discord.ButtonStyle.success

        store_buttons(task_key, label, action) # must replace old button instance
        return label, style
    

def load_buttons():
      button_path = QUEUE_DIR / f"{uuid.uuid4()}.json"
      if not button_path.exists():
          button_path.mkdir(parents=True, exist_ok=True)
          return {}
      with open(button_path, "r", encoding="utf-8") as f:
          return json.load(f)


def store_buttons(task_key: str, label: str, action: str):
      data = load_buttons()
      button = (label, f"task:{task_key}:{label}")
      if task_key in data and len(data[task_key]) == 2:
            if action == "working":
                  data[task_key][0] = button
            else:
                  data[task_key][1] = button 
      else:
            # first index should store "working" button
            if task_key not in data: data[task_key] = [button]
            else: data[task_key].append(button)

      