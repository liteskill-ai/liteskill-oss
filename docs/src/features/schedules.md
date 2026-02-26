# Schedules

Schedules enable cron-based recurring execution of agent runs.

## How It Works

1. Create a schedule with a cron expression, timezone, and run template
2. `ScheduleTick` (a periodic GenServer) checks for due schedules every minute
3. When a schedule is due, it enqueues a `ScheduleWorker` Oban job
4. The worker creates and starts a run based on the schedule's template
5. `next_run_at` is recalculated for the next occurrence

## Schedule Configuration

Each schedule defines:

- **Name** — Display name
- **Cron expression** — Standard 5-field format (minute, hour, day-of-month, month, day-of-week)
- **Timezone** — The cron expression is interpreted in this timezone
- **Team definition** — The agent team to execute
- **Enabled flag** — Schedules can be toggled on/off
- **Status** — `active` or other lifecycle states

## Cron Parser

The built-in cron parser supports:

- Wildcards (`*`)
- Step values (`*/5`)
- Exact values (`30`)
- Comma-separated lists (`1,15,30`)

## Access Control

Schedules use the standard ACL system. Only the owner can update or delete a schedule.

## Routes

- `/schedules` — List all schedules
- `/schedules/new` — Create a new schedule
- `/schedules/:schedule_id` — View/edit a schedule
