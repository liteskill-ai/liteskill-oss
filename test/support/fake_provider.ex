defmodule Liteskill.LLM.FakeProvider do
  @moduledoc """
  Fake LLM provider for testing StreamHandler's tool-calling path.

  Reads events from `Process.get(:fake_provider_events)` and invokes the
  callback with each one. Supports multi-round tool-calling by reading
  from `Process.get(:fake_provider_events_round_N)` for subsequent rounds.
  """

  @behaviour Liteskill.LLM.Provider

  @impl true
  def converse(_model_id, _messages, _opts) do
    {:ok, %{"output" => %{"message" => %{"content" => [%{"text" => "fake"}]}}}}
  end

  @impl true
  def converse_stream(_model_id, _messages, callback, _opts) do
    round = Process.get(:fake_provider_round, 0)
    Process.put(:fake_provider_round, round + 1)

    events =
      Process.get(:"fake_provider_events_round_#{round}") ||
        Process.get(:fake_provider_events, [])

    Enum.each(events, callback)
    :ok
  end
end
