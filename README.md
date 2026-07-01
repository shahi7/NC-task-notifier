# Discord Task Bot Guide

This is an overview to the Discord task bot and a simple usage and onboarding guide.

## Purpose

The system connects Nextcloud tasks to Discord DMs so assignees can receive task notifications, update task status and deadlines, and get follow-up reminders or updates when task details change in Nextcloud. 

The polling script checks the Nextcloud calendar for new and changed tasks, writes notification jobs into a queue, and the Discord bot processes that queue and sends DMs. 

## Core features

- New tasks are shared with tagged assignees by Discord DM.
- Interactive task buttons in Discord for status updating (such as accepting or completing a task).
- Ability for assignees to extend task deadlines.
- Follow-up reminder messages.
- Send update notifications when task details such as deadline, description, subject, or location change in Nextcloud.
- Send task DMs to newly added assignees and notify removed assignees of removal.
- Retry queue to work around temporary Discord/Nextcloud network failures.

## Running the system

The system has two long-running responsibilities:

- **Poller**: checks Nextcloud regularly and enqueues work.
- **Bot**: stays connected to Discord and processes queued notifications.

## How work flows

1. A delegator creates or modifies a task in Nextcloud.
2. The poller reads new/modified tasks from the tasks calendar.
3. The script stores task metadata locally.
4. A DM job is queued for each target Discord user.
5. The bot processes the DM queue and sends/follows-up in Discord DMs.
6. Assignees interact with the DM to update task state or deadline.
7. The system syncs assignee updates back to Nextcloud.

## Delegator setup

Delegators are the people creating and assigning tasks in Nextcloud.

- Use the correct shared Nextcloud calendar configured for the bot.
- Create tasks in Apps > Tasks. Tasks will be visible in the corresponding calendar.
- Add assignees by entering assignee first names in the Tags section.

See the below image for a visual guide on Nextcloud task creation.

<img width="403" height="609" alt="Screenshot 2026-06-30 at 8 57 25 PM" src="https://github.com/user-attachments/assets/445d0e91-e61b-4c2b-bcf2-6e18c4530c46" />

## Assignee setup

Assignees are the people who receive task DMs and interact with them in Discord.

- Join the SAA Discord server.
- Allow DMs from server members for the SAA server.

### What assignees will see

- A DM containing the task details.
- Buttons to accept, cancel, complete, or update a deadline depending on task state.
- Follow-up reminder messages that reference the original task DM.
- Update messages when the task changes.

<div align="center">
  <img src="https://github.com/user-attachments/assets/b29e2a86-879d-4849-af27-b6f346ed6f5e" width="45%" />
  <img src="https://github.com/user-attachments/assets/dfff0991-d6e6-4d02-9462-71c8225a9ef1" width="45%" />
</div>

## Configuration

The most important environment values usually include:

- `NEXTCLOUD_USER` and `NEXTCLOUD_PASS`: app credentials for the delegator Nextcloud account, generated in account settings.
- `CALENDAR_URL`: URL for target task calendar.
- `USER_MAP_DC`: mapping from task assignee labels to Discord user IDs.
- `REMINDER_DELTAS`: how long before a deadline reminder should be sent.

## Error handling

The system is designed to tolerate temporary failures rather than crash and drop work.

### Queue behavior

- New notification jobs are written to a pending queue. Failed jobs move to a “failed” queue and are retried later.
- Update sync jobs from Discord to Nextcloud may fail due to temporary network issues, and are queued to be retried later.

### Common failure cases

This information is useful for delegators and developers when troubleshooting.

| Problem | Likely cause | What to check |
|---|---|---|
| No DM sent for a new task | Assignee mapping missing or empty | Confirm `USER_MAP_DC` entry and task assignee label match |
| No DM sent to one user | Discord DMs blocked | Check that the assignee allows DMs from the shared server |
| Bot starts but sends nothing | Poller not running or queue empty | Check poller logs and pending queue files |
| Poller runs but finds no changes | Sync token issue or wrong calendar | Check calendar URL, sync token file, and poller logs |
| Repeated reminders every run | Task incorrectly marked updated or reminder state not persisted | Check stored task state and reminder delta tracking |
| Update button works in Discord but not in Nextcloud | CALDAV write failure | Check Nextcloud credentials, URL, and update logs |
| Follow-up jobs keep failing | Bot-side message edit/reference problem | Check failed queue files and bot logs |


