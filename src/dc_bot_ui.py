"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
import asyncio 
import calendar 
from datetime import date 
import discord # type: ignore 
from helpers import load_state 
from update_nextcloud import update_and_retry 
from helpers import notify_delegator 


class TaskStatusView(discord.ui.View):
    def __init__(self, task_key: str, status: str = "pending"):
        super().__init__(timeout=None)

        self.task_key = str(task_key)

        state = load_state()
        task = state.get(self.task_key, {})
        self.text = task.get("text", "")

        # rendering labels + buttons based on current status of task
        if status in ("pending", "cancelled"):
            self.add_item(TaskButton(task_key, "working", "Accept Task", discord.ButtonStyle.primary))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
            self.add_item(ChangeDeadlineButton(task_key))
            return
        elif status == "working":
            self.add_item(TaskButton(task_key, "working", "Cancel Task", discord.ButtonStyle.danger))
            self.add_item(TaskButton(task_key, "done", "Mark Completed", discord.ButtonStyle.success))
            self.add_item(ChangeDeadlineButton(task_key))
        elif status == "done":
            self.add_item(TaskButton(task_key, "done", "Completed! Click to undo", discord.ButtonStyle.secondary))
            return


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
        await interaction.response.defer(ephemeral=True)
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
        old_view = TaskStatusView(task_key, status=current)
        updated_view = TaskStatusView(task_key, status=new_status)

        updated_view = TaskStatusView(task_key, status=new_status)
        await interaction.edit_original_response(
                content=updated_view.text,
                view=updated_view
        )

        # state save (w/ new status) happens in update_nextcloud_task
        try:
                _, message = await update_and_retry(task_key, new_status)
        except Exception as e:
                await interaction.edit_original_response(
                        content=old_view.text,
                        view=old_view
                )
                await interaction.followup.send(f"Nextcloud update failed; will be retried in 5 minutes: {e}", ephemeral=True)
                return
        
        if message:
                await interaction.followup.send(message, ephemeral=True)

        print("updating view\n\n")
        await asyncio.to_thread(notify_delegator, action, task_key)


class ChangeDeadlineButton(discord.ui.Button):
    def __init__(self, task_key: str):
        super().__init__(
            label="Extend Deadline",
            style=discord.ButtonStyle.secondary,
            custom_id=f"deadline:{task_key}:open",
        )

    async def callback(self, interaction: discord.Interaction):
        _, task_key, _ = self.custom_id.split(":")
        await interaction.response.send_modal(DateModal(task_key))


class DateModal(discord.ui.Modal):
    def __init__(self, task_key: str):
        super().__init__(
            title="Extend Deadline",
            custom_id=f"deadline:{task_key}:modal"
        )
        self.task_key = task_key
        # string select wrapped in a label
        self.month = discord.ui.Label(
                text="Month",
                component=discord.ui.Select(
                        custom_id=f"deadline:{task_key}:month",
                        placeholder="Month",
                        required=True,
                        options = [
                                discord.SelectOption(label=calendar.month_name[i], value=str(i))
                                for i in range(1, 13)
                        ]
                )
        )
        self.add_item(self.month)

        self.date = discord.ui.Label(
                text="Date",
                component=discord.ui.TextInput(
                        max_length=2,
                        min_length=2,
                        required=True,
                        custom_id=f"deadline:{task_key}:date",
                        style=discord.TextStyle.short,
                        placeholder="DD",
                )
        )
        self.add_item(self.date)

    async def on_submit(self, interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True)
        month = self.month.component.values[0]
        raw_day = self.date.component.value

        try:
                day = int(raw_day)
        except ValueError:
                await interaction.followup.send(
                        "Date must be an integer from 1-31.",
                        ephemeral=True
                )
                return

        today = date.today()

        # check if valid date entered
        candidate = None
        for y in range(2): # current and next year
                try:
                        d = date(int(today.year) + y, int(month), day)
                        if d >= today:
                                candidate = d
                                break
                except ValueError:
                        continue

        if candidate is None:
                await interaction.followup.send(
                        "Invalid date.",
                        ephemeral=True
                )
                return

        # convert to closest date in ISO format
        new_deadline_iso = candidate.isoformat()
        try:
                await update_and_retry(self.task_key, new_status="", deadline=new_deadline_iso)
        except Exception as e:
                await interaction.followup.send(f"Deadline update failed: {e}", ephemeral=True)
                return

        await interaction.followup.send(
            content=f"Deadline successfully updated.",
            ephemeral=True
        )


