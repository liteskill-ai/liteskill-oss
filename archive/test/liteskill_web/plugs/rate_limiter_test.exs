defmodule LiteskillWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.Plugs.RateLimiter

  # The ETS table is created by Application.start in test env.

  defp build_conn(ip) do
    :get
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, ip)
  end

  defp build_conn_with_user(user_id) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Conn.assign(:current_user, %{id: user_id})
  end

  describe "sweep_stale/1" do
    test "removes old window entries from ETS" do
      # Use a window number that's well before the current one
      current_window = div(System.monotonic_time(:millisecond), 60_000)
      old_window = current_window - 10
      old_key = {"test:sweep-#{System.unique_integer([:positive])}", old_window}
      :ets.insert(:liteskill_rate_limiter, {old_key, 5})

      # Verify it exists
      assert :ets.lookup(:liteskill_rate_limiter, old_key) == [{old_key, 5}]

      # Sweep with default max_age
      deleted = RateLimiter.sweep_stale()
      assert deleted >= 1

      # Verify it's gone
      assert :ets.lookup(:liteskill_rate_limiter, old_key) == []
    end

    test "keeps current window entries" do
      # Insert an entry with a current window number
      current_window = div(System.monotonic_time(:millisecond), 60_000)
      current_key = {"test:sweep-current-#{System.unique_integer([:positive])}", current_window}
      :ets.insert(:liteskill_rate_limiter, {current_key, 3})

      RateLimiter.sweep_stale()

      # Current entry should still exist
      assert :ets.lookup(:liteskill_rate_limiter, current_key) == [{current_key, 3}]

      # Clean up
      :ets.delete(:liteskill_rate_limiter, current_key)
    end
  end

  describe "call/2" do
    test "allows requests under the limit" do
      opts = RateLimiter.init(limit: 100, window_ms: 60_000)
      ip = {10, 0, [:positive] |> System.unique_integer() |> rem(254), 1}
      conn = build_conn(ip)

      result = RateLimiter.call(conn, opts)
      refute result.halted
    end

    test "blocks requests over the limit with JSON content-type" do
      ip = {10, 99, [:positive] |> System.unique_integer() |> rem(254), 1}
      opts = RateLimiter.init(limit: 3, window_ms: 60_000)

      # Make 3 requests (all should pass)
      for _ <- 1..3 do
        conn = build_conn(ip)
        result = RateLimiter.call(conn, opts)
        refute result.halted
      end

      # 4th request should be blocked
      conn = build_conn(ip)
      result = RateLimiter.call(conn, opts)
      assert result.halted
      assert result.status == 429
      assert result |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "application/json"
    end

    test "uses user_id key when authenticated" do
      user_id = Ecto.UUID.generate()
      opts = RateLimiter.init(limit: 2, window_ms: 60_000)

      # First two requests pass
      for _ <- 1..2 do
        conn = build_conn_with_user(user_id)
        result = RateLimiter.call(conn, opts)
        refute result.halted
      end

      # Third request blocked
      conn = build_conn_with_user(user_id)
      result = RateLimiter.call(conn, opts)
      assert result.halted
      assert result.status == 429
    end

    test "different users have separate limits" do
      opts = RateLimiter.init(limit: 1, window_ms: 60_000)

      conn1 = build_conn_with_user(Ecto.UUID.generate())
      result1 = RateLimiter.call(conn1, opts)
      refute result1.halted

      conn2 = build_conn_with_user(Ecto.UUID.generate())
      result2 = RateLimiter.call(conn2, opts)
      refute result2.halted
    end

    test "includes retry-after header when rate limited" do
      ip = {10, 88, [:positive] |> System.unique_integer() |> rem(254), 1}
      opts = RateLimiter.init(limit: 1, window_ms: 60_000)

      # Exhaust limit
      RateLimiter.call(build_conn(ip), opts)

      # Check headers on blocked request
      conn = build_conn(ip)
      result = RateLimiter.call(conn, opts)
      assert result.halted
      assert Plug.Conn.get_resp_header(result, "retry-after") == ["60"]
    end
  end
end
