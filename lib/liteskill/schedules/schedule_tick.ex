defmodule Liteskill.Schedules.ScheduleTick do
  @moduledoc """
  Periodic GenServer that checks for due schedules every minute
  and enqueues `ScheduleWorker` jobs for each.

  Only runs in non-test environments. Computes `next_run_at` on
  schedule creation if not already set.
  """

  use GenServer

  alias Liteskill.Schedules
  alias Liteskill.Schedules.ScheduleWorker

  require Logger

  @tick_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    check_due_schedules()
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp check_due_schedules do
    now = DateTime.utc_now()

    now
    |> Schedules.list_due_schedules()
    |> Enum.each(fn schedule ->
      case %{"schedule_id" => schedule.id, "user_id" => schedule.user_id}
           |> ScheduleWorker.new()
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        # coveralls-ignore-start — Oban insert failures require Oban/DB to be down
        {:error, reason} ->
          Logger.error("Failed to enqueue schedule #{schedule.id}: #{inspect(reason)}")
          # coveralls-ignore-stop
      end
    end)
  rescue
    # coveralls-ignore-start — defensive: only reached on transient DB errors
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.error("ScheduleTick error: #{Exception.message(e)}")
      # coveralls-ignore-stop
  end
end
