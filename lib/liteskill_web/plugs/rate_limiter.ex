defmodule LiteskillWeb.Plugs.RateLimiter do
  @moduledoc """
  Simple ETS-based rate limiter plug.

  Uses fixed-window counters per client (user_id or IP address).
  Extremely generous defaults — purely for protection against runaway
  clients or accidental loops, not to throttle normal usage.

  Periodically sweeps stale window buckets to prevent memory leaks.

  ## Options

    * `:limit` - max requests per window (default 1000)
    * `:window_ms` - window duration in milliseconds (default 60_000)
  """

  @behaviour Plug

  import Plug.Conn

  @table :liteskill_rate_limiter

  @default_limit 1000
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

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    key = rate_limit_key(conn)
    window = div(System.monotonic_time(:millisecond), window_ms)
    bucket_key = {key, window}

    count =
      try do
        :ets.update_counter(@table, bucket_key, {2, 1}, {bucket_key, 0})
      rescue
        # coveralls-ignore-start
        ArgumentError ->
          0
          # coveralls-ignore-stop
      end

    if count <= limit do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("retry-after", to_string(div(window_ms, 1000)))
      |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
      |> halt()
    end
  end

  @doc """
  Removes ETS entries for windows older than `max_age_ms` (default 2 minutes).
  Called periodically by `RateLimiter.Sweeper` to prevent unbounded memory growth.
  """
  def sweep_stale(max_age_ms \\ 120_000) do
    cutoff = div(System.monotonic_time(:millisecond) - max_age_ms, @default_window_ms)

    # Match records {{key, window}, count} where window <= cutoff
    match_spec = [{{{:_, :"$1"}, :_}, [{:"=<", :"$1", cutoff}], [true]}]

    try do
      :ets.select_delete(@table, match_spec)
    rescue
      # coveralls-ignore-next-line
      ArgumentError -> 0
    end
  end

  defp rate_limit_key(conn) do
    case conn.assigns do
      %{current_user: %{id: user_id}} -> "user:#{user_id}"
      _ -> "ip:#{:inet.ntoa(conn.remote_ip)}"
    end
  end
end
