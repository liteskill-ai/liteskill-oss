defmodule LiteskillWeb.Plugs.RateLimiter.Sweeper do
  @moduledoc """
  Periodic sweeper that cleans stale rate limiter ETS buckets.
  Runs every 60 seconds to remove expired window entries.
  """

  use GenServer

  @sweep_interval_ms 60_000

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
    LiteskillWeb.Plugs.RateLimiter.sweep_stale()
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
