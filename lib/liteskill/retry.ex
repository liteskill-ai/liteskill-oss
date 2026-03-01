defmodule Liteskill.Retry do
  @moduledoc """
  Shared retry utilities: exponential backoff with jitter and interruptible sleep.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @doc """
  Calculates exponential backoff with jitter.

  ## Options

    * `:rate_limited` - when `true`, applies a 3x multiplier (for 429 errors)

  ## Examples

      iex> backoff = Liteskill.Retry.calculate_backoff(1000, 0)
      iex> backoff >= 1000 and backoff <= 2000
      true

      iex> backoff = Liteskill.Retry.calculate_backoff(1000, 0, rate_limited: true)
      iex> backoff >= 3000 and backoff <= 6000
      true

  """
  @spec calculate_backoff(non_neg_integer(), non_neg_integer(), keyword()) :: non_neg_integer()
  def calculate_backoff(base_ms, attempt, opts \\ []) do
    base_ms = if Keyword.get(opts, :rate_limited, false), do: base_ms * 3, else: base_ms
    jitter = :rand.uniform()
    trunc(base_ms * Integer.pow(2, attempt) * (1 + jitter))
  end

  @doc """
  Sleeps for `ms` milliseconds but can be interrupted by a `:cancel` message.

  Returns `:ok` after sleeping, or `:cancelled` if a `:cancel` message is received.
  """
  @spec interruptible_sleep(non_neg_integer()) :: :ok | :cancelled
  def interruptible_sleep(ms) do
    receive do
      :cancel -> :cancelled
    after
      ms -> :ok
    end
  end
end
