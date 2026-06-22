"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
# TODO: progress bar, stale buttons, clear cache (queue + buttons), reflect updates from NC end (automatic?)
import asyncio
import json
from pathlib import Path
import discord # type: ignore
from helpers import load_state, save_state
from update_nextcloud import update_nextcloud_task
from helpers import notify_delegator

BUTTON_DIR = Path("buttons")
BUTTON_FILE = BUTTON_DIR / "buttons.json"

class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, new_status: str = "pending", clicked: bool = False, chosen_action: str | None = None):
        super().__init__(timeout=None)

        for action in ("working", "done"):
            # not rendering working button once completed
            if new_status == "done" and action == "working": continue

            self.add_item(TaskButton(task_key, action, clicked=clicked, chosen_action=chosen_action))

        
class TaskButton(discord.ui.Button):
    def __init__(self, task_key: str, action: str, clicked: bool = False, chosen_action: str | None = None):
        label, style = self.button_state(action, task_key, clicked, chosen_action)

        super().__init__(
                label=label,
                style=style,
                custom_id=f"task:{task_key}:{action}"
                # disabled=disabled,
        )

    async def callback(self, interaction: discord.Interaction):
        print("before defer")
        await interaction.response.defer()
        print("after defer")
        state = load_state()

        _, task_key, action = self.custom_id.split(":")
        task = state.get(task_key) 

        current = task.get("status", "pending")

        if action == "working":
            if current == "pending":
                new_status = "working"
            else:
                new_status = "pending"
        else:  # done
            if current == "done":
                new_status = "working"
            else:
                new_status = "done"

        # state save in update_nextcloud_task
        ok, message = update_nextcloud_task(task_key, new_status)
        print(f"new status: {new_status}\n")
        if not ok:
                await interaction.followup.send(message, ephemeral=True)
                return

        updated_view = TaskStatusView(task_key, chosen_action=action, clicked=True, new_status=new_status)
        await interaction.edit_original_response(view=updated_view)
        await interaction.followup.send(message, ephemeral=True)
        await asyncio.to_thread(notify_delegator, action, task_key)


    def button_state(self, action: str, task_key: str, clicked: bool = False, chosen_action: str | None = None):
        state = load_state()

        task = state.get(task_key)
        if not task:
                return "Missing task", discord.ButtonStyle.secondary
        
        # first render
        (label, style) = ("Accept", discord.ButtonStyle.primary) \
                        if action == "working" else \
                        ("Mark Completed", discord.ButtonStyle.success)
                
        # click done twice to change; only marks as done
        # first button still renders after done
        # for cancellations TODO not working
        if clicked:
                if state[task_key]["status"] == "pending":
                     if action == "working":
                          label = "Accept"
                          style = discord.ButtonStyle.primary
                     else: # done
                          label = "Mark Completed"
                          style = discord.ButtonStyle.success
                elif state[task_key]["status"] == "working":
                     if action == "working":
                          label = "In-Progress! Click to undo"
                          style = discord.ButtonStyle.secondary
                     else: # done
                          label = "Mark Completed"
                          style = discord.ButtonStyle.success
                elif state[task_key]["status"] == "done":
                     # only done button gets rendered
                     label = "Completed! Click to undo"
                     style = discord.ButtonStyle.secondary
                
        return label, style
    

def render_buttons(task_key: str, clicked: bool = False, chosen_action: str | None = None):
    data = load_buttons()
    state = load_state()
    buttons = []
    task = state.get(task_key)

    if not task:
        return []

    for label, button_id in data.get(task_key, []):
        action = button_id.split(":")[2]

        button_clicked = label not in ["Accept", "Mark Completed"]

        buttons.append(
            TaskButton(
                task_key=task_key,
                action=action,
                custom_id=button_id,
                clicked=clicked or button_clicked,
                chosen_action=chosen_action,
            )
        )

    return buttons


def load_buttons():
      BUTTON_DIR.mkdir(parents=True, exist_ok=True)
      if not BUTTON_FILE.exists():
          return {}
      with open(BUTTON_FILE, "r", encoding="utf-8") as f:
          return json.load(f)


def store_buttons(task_key: str, label: str, action: str):
      data = load_buttons()
      button = (label, f"task:{task_key}:{action}")
      if task_key in data and len(data[task_key]) == 2:
            if action == "working":
                  data[task_key][0] = button
            else:
                  data[task_key][1] = button 
      else:
            # first index should store "working" button
            if task_key not in data: data[task_key] = [button]
            else: data[task_key].append(button)
        
      with open(BUTTON_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

      