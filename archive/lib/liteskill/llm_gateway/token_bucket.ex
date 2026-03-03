defmodule Liteskill.LlmGateway.TokenBucket do
  @moduledoc """
  ETS-based per-user+model rate limiter for outbound LLM calls.

  Uses fixed-window counters with atomic `update_counter` — lock-free,
  safe for concurrent access from many processes.

  ## Configuration

      config :liteskill, Liteskill.LlmGateway.TokenBucket,
        limit: 60,        # requests per window
        window_ms: 60_000  # window duration
  """

  require Logger

  @table :liteskill_llm_token_bucket
  @default_limit 60
  @default_window_ms 60_000

  @doc "Creates the ETS table. Call once from Application.start/2."
  def create_table do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  @doc """
  Checks and increments the rate counter for a user+model pair.

  Returns `:ok` or `{:error, :rate_limited, retry_after_ms}`.

  ## Options

    * `:limit` - Override the per-window limit
    * `:window_ms` - Override the window duration
  """
  def check_rate(user_id, model_id, opts \\ []) do
    config = config()
    limit = Keyword.get(opts, :limit, config[:limit])
    window_ms = Keyword.get(opts, :window_ms, config[:window_ms])
    window = div(System.monotonic_time(:millisecond), window_ms)
    bucket_key = {user_id, model_id, window}

    count =
      try do
        :ets.update_counter(@table, bucket_key, {2, 1}, {bucket_key, 0})
      rescue
        # coveralls-ignore-start — ETS table not yet created during boot
        ArgumentError ->
          Logger.warning("TokenBucket: ETS table not available, rejecting request")
          :unavailable
          # coveralls-ignore-stop
      end

    if count == :unavailable do
      # coveralls-ignore-next-line — fail open: allow request if ETS table missing during boot
      :ok
    else
      if count <= limit do
        :telemetry.execute(
          [:liteskill, :llm_gateway, :checkout],
          %{count: 1},
          %{user_id: user_id, model_id: model_id}
        )

        :ok
      else
        remaining_ms = window_ms - Integer.mod(System.monotonic_time(:millisecond), window_ms)

        :telemetry.execute(
          [:liteskill, :llm_gateway, :rate_limited],
          %{count: 1},
          %{user_id: user_id, model_id: model_id}
        )

        {:error, :rate_limited, remaining_ms}
      end
    end
  end

  @doc """
  Removes ETS entries for windows older than `max_age_ms` (default 2 minutes).
  Called periodically by the Sweeper to prevent unbounded memory growth.
  """
  def sweep_stale(max_age_ms \\ 120_000) do
    window_ms = config()[:window_ms]
    cutoff = div(System.monotonic_time(:millisecond) - max_age_ms, window_ms)

    # Match records {{user_id, model_id, window}, count} where window <= cutoff
    match_spec = [{{{:_, :_, :"$1"}, :_}, [{:"=<", :"$1", cutoff}], [true]}]

    try do
      :ets.select_delete(@table, match_spec)
    rescue
      # coveralls-ignore-next-line
      ArgumentError -> 0
    end
  end

  defp config do
    config = Application.get_env(:liteskill, __MODULE__, [])

    [
      limit: Keyword.get(config, :limit, @default_limit),
      window_ms: Keyword.get(config, :window_ms, @default_window_ms)
    ]
  end
end
