defmodule Liteskill.Schedules.ScheduleWorker do
  @moduledoc """
  Oban worker that checks for due schedules and creates runs.

  Enqueued periodically by `Liteskill.Schedules.ScheduleTick`.
  For each enabled schedule whose `next_run_at` is in the past,
  creates a new run and kicks off the runner.
  """

  use Oban.Worker,
    queue: :agent_runs,
    max_attempts: 1,
    unique: [period: 55, fields: [:args], keys: [:schedule_id]]

  alias Liteskill.Runs
  alias Liteskill.Runs.Runner
  alias Liteskill.Schedules

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"schedule_id" => schedule_id, "user_id" => user_id}}) do
    case Schedules.get_schedule(schedule_id, user_id) do
      {:ok, schedule} ->
        if schedule.enabled do
          execute_schedule(schedule, user_id)
        else
          Logger.info("Schedule #{schedule.name} is disabled, skipping")
          :ok
        end

      {:error, :not_found} ->
        Logger.warning("Schedule #{schedule_id} not found, skipping")
        :ok
    end
  end

  defp execute_schedule(schedule, user_id) do
    run_attrs = %{
      name: "#{schedule.name} — #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M")}",
      prompt: schedule.prompt,
      topology: schedule.topology,
      context: schedule.context,
      timeout_ms: schedule.timeout_ms,
      max_iterations: schedule.max_iterations,
      team_definition_id: schedule.team_definition_id,
      user_id: user_id
    }

    case Runs.create_run(run_attrs) do
      {:ok, run} ->
        Logger.info("Schedule #{schedule.name} created run #{run.id}")

        # Update schedule timestamps
        now = DateTime.truncate(DateTime.utc_now(), :second)
        next = Schedules.compute_next_run(schedule.cron_expression, schedule.timezone, now)

        Schedules.update_schedule(schedule.id, user_id, %{
          last_run_at: now,
          next_run_at: next
        })

        # Start the runner asynchronously
        Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
          Runner.run(run.id, user_id)
        end)

        :ok

      # coveralls-ignore-start — defensive: schedule attrs are always valid
      {:error, reason} ->
        Logger.error("Schedule #{schedule.name} failed to create run: #{inspect(reason)}")
        {:error, inspect(reason)}
        # coveralls-ignore-stop
    end
  end
end
