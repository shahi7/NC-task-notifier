"""
Defines UI elements for Discord notifications, and updates UI on user click
"""
# TODO: progress bar, stale buttons, clear cache (queue + buttons), reflect updates from NC end (automatic?)
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
                await interaction.followup.send(f"Nextcloud update failed after retries: {e}", ephemeral=True)
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
        picker = DeadlinePickerView(task_key)
        await interaction.response.edit_message(view=picker)


# view for updating deadline
class DeadlinePickerView(discord.ui.View):
    def __init__(self, task_key: str):
        super().__init__(timeout=300)
        self.task_key = str(task_key)
        self.selected_month = None
        self.selected_day = None
        self.text = load_state()[task_key]["text"]

        self.add_item(MonthSelect(task_key))
        self.add_item(DaySelect(task_key))
        self.add_item(SubmitDeadlineButton(task_key))
        self.add_item(CancelDeadlineButton(task_key))


# stores new deadline month value
class MonthSelect(discord.ui.Select):
    def __init__(self, task_key: str):
        self.task_key = task_key
        options = [
            discord.SelectOption(label=calendar.month_name[i], value=str(i))
            for i in range(1, 13)
        ]
        super().__init__(
            placeholder="Month",
            min_values=1,
            max_values=1,
            options=options,
            custom_id=f"deadline:{task_key}:month",
        )

    async def callback(self, interaction: discord.Interaction):
        self.view.selected_month = int(self.values[0])
        
        await interaction.edit_original_response(
                content=self.view.text,
                view=self.view
        )


# stores new deadline day value
class DaySelect(discord.ui.Select):
    def __init__(self, task_key: str):
        options = [
            discord.SelectOption(label=str(i), value=str(i))
            for i in range(1, 32)
        ]
        super().__init__(
            placeholder="Day",
            min_values=1,
            max_values=1,
            options=options,
            custom_id=f"deadline:{task_key}:day",
        )

    async def callback(self, interaction: discord.Interaction):
        self.view.selected_day = int(self.values[0])
        await interaction.response.edit_message(
                content=self.view.text,
                view=self.view
        )


class SubmitDeadlineButton(discord.ui.Button):
    def __init__(self, task_key: str):
        super().__init__(
            label="Submit",
            style=discord.ButtonStyle.success,
            custom_id=f"deadline:{task_key}:submit",
        )

    async def callback(self, interaction: discord.Interaction):
        view = self.view
        if view.selected_month is None or view.selected_day is None:
            await interaction.response.send_message(
                "Choose both a month and a day first.",
                ephemeral=True,
            )
            return

        await interaction.response.defer(ephemeral=True)

        today = date.today()
        year = today.year

        try:
            new_deadline = date(year, view.selected_month, view.selected_day)
        except ValueError:
            await interaction.followup.send("That date is invalid.", ephemeral=True)
            return

        if new_deadline < today:
            await interaction.followup.send("Deadline must be today or later.", ephemeral=True)
            return

        task_key = view.task_key

        try:
            _, message = await update_and_retry(task_key, new_deadline.isoformat())
        except Exception as e:
            await interaction.followup.send(
                f"Nextcloud deadline update failed after retries: {e}",
                ephemeral=True,
            )
            return

        await asyncio.to_thread(notify_delegator, "deadline_changed", task_key)

        state = load_state()
        task = state.get(task_key, {})
        status = task.get("status", "pending")

        await interaction.edit_original_response(
            content=task.get("text", ""),
            view=TaskStatusView(task_key, status=status),
        )
        if message:
                await interaction.followup.send(message, ephemeral=True)


class SubmitDeadlineButton(discord.ui.Button):
    def __init__(self, task_key: str):
        super().__init__(
            label="Submit",
            style=discord.ButtonStyle.success,
            custom_id=f"deadline:{task_key}:submit",
        )

    async def callback(self, interaction: discord.Interaction):
        view = self.view
        if view.selected_month is None or view.selected_day is None:
            await interaction.response.send_message(
                "Choose both a month and a day first.",
                ephemeral=True,
            )
            return

        await interaction.response.defer(ephemeral=True)

        today = date.today()
        year = today.year

        try:
            new_deadline = date(year, view.selected_month, view.selected_day)
        except ValueError:
            await interaction.followup.send("That date is invalid.", ephemeral=True)
            return

        if new_deadline < today:
            await interaction.followup.send("Deadline must be today or later.", ephemeral=True)
            return

        task_key = view.task_key

        try:
            _, message = await update_and_retry(task_key, new_deadline.isoformat())
        except Exception as e:
            await interaction.followup.send(
                f"Nextcloud deadline update failed after retries: {e}",
                ephemeral=True,
            )
            return

        await asyncio.to_thread(notify_delegator, "deadline_changed", task_key)

        state = load_state()
        task = state.get(task_key, {})
        status = task.get("status", "pending")

        await interaction.edit_original_response(
            content=task.get("text", ""),
            view=TaskStatusView(task_key, status=status),
        )
        await interaction.followup.send(message, ephemeral=True)


class CancelDeadlineButton(discord.ui.Button):
    def __init__(self, task_key: str):
        super().__init__(
            label="Back",
            style=discord.ButtonStyle.secondary,
            custom_id=f"deadline:{task_key}:cancel",
        )

    async def callback(self, interaction: discord.Interaction):
        state = load_state()
        task = state.get(self.view.task_key, {})
        status = task.get("status", "pending")
        await interaction.response.edit_message(
            content=task.get("text", ""),
            view=TaskStatusView(self.view.task_key, status=status),
        )


async def apply_deadline(interaction: discord.Interaction, view: DeadlinePickerView):
    if view.selected_month is None or view.selected_day is None:
        await interaction.response.edit_message(view=view)
        return

    today = date.today()
    year = today.year

    # check if valid
    try:
        new_deadline = date(year, view.selected_month, view.selected_day)
    except ValueError:
        await interaction.response.send_message("That date is invalid.", ephemeral=True)
        return

    if new_deadline < today:
        await interaction.response.send_message("Deadline must be today or later.", ephemeral=True)
        return

    task_key = view.task_key

    try:
        _, message = await update_and_retry(task_key, load_state()[task_key]["status"], new_deadline.isoformat())
        await asyncio.to_thread(notify_delegator, "deadline_changed", task_key)
    except Exception as e:
        await interaction.response.send_message(
            f"Nextcloud deadline update failed after retries: {e}",
            ephemeral=True,
        )
        return

    await asyncio.to_thread(notify_delegator, "deadline_changed", task_key)

    state = load_state()
    task = state.get(task_key, {})
    status = task.get("status", "pending")

    await interaction.response.edit_message(
        content=task.get("text", ""),
        view=TaskStatusView(task_key, status=status),
    )
    await interaction.followup.send(message, ephemeral=True)

