defmodule Liteskill.RetryTestHelpers do
  @moduledoc """
  Shared helpers for tests that use Agent-based call counters
  to track retry attempts or multi-call sequences.
  """

  @doc """
  Starts an Agent-based counter at 0 and returns its pid.

  ## Example

      counter = retry_counter()
      assert next_count(counter) == 0
      assert next_count(counter) == 1
  """
  def retry_counter do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Gets the current count and atomically increments the counter.
  Returns the count *before* incrementing.
  """
  def next_count(counter) do
    Agent.get_and_update(counter, fn n -> {n, n + 1} end)
  end

  @doc """
  Returns the current count without incrementing.
  """
  def get_count(counter) do
    Agent.get(counter, & &1)
  end
end
