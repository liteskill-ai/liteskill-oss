defmodule Liteskill.Chat.StreamRecovery do
  @moduledoc """
  Periodically sweeps for conversations stuck in streaming status and recovers them.

  Conversations can become orphaned when the streaming Task exits normally with an
  error tuple (so no :DOWN crash signal) or when the LiveView that spawned the task
  disconnects before receiving the :DOWN message.
  """

  use GenServer

  require Logger

  @sweep_interval_ms to_timeout(minute: 2)
  @threshold_minutes 5

  def start_link(opts \\ []) do
    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    threshold = Keyword.get(opts, :threshold_minutes, @threshold_minutes)

    GenServer.start_link(__MODULE__, %{interval: interval, threshold: threshold},
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl true
  def init(state) do
    schedule_sweep(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.threshold)
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  # coveralls-ignore-start — catch-all for unexpected messages (e.g. late monitors)
  def handle_info(_msg, state), do: {:noreply, state}
  # coveralls-ignore-stop

  defp sweep(threshold_minutes) do
    stuck = Liteskill.Chat.list_stuck_streaming(threshold_minutes)

    if stuck != [] do
      Logger.info("StreamRecovery: recovering #{length(stuck)} stuck conversation(s)")

      Enum.each(stuck, fn conversation ->
        Logger.info("StreamRecovery: recovering #{conversation.id}")

        try do
          Liteskill.Chat.recover_stream_by_id(conversation.id)
        rescue
          # coveralls-ignore-start — requires transient DB/Ecto error to trigger
          e ->
            Logger.error("StreamRecovery: failed to recover #{conversation.id}: #{Exception.message(e)}")
            # coveralls-ignore-stop
        end
      end)
    end
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
