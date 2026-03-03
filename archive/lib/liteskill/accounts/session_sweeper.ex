defmodule Liteskill.Accounts.SessionSweeper do
  @moduledoc """
  Periodic sweeper that deletes expired user sessions.
  Runs every 5 minutes.
  """

  use GenServer

  @sweep_interval_ms 300_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @sweep_interval_ms)
    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Liteskill.Accounts.delete_expired_sessions()
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
