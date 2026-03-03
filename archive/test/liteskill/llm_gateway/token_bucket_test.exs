defmodule Liteskill.LlmGateway.TokenBucketTest do
  use ExUnit.Case, async: true

  alias Liteskill.LlmGateway.TokenBucket

  # Use a unique per-test table to allow async
  setup do
    table = :"test_bucket_#{System.unique_integer([:positive])}"

    :ets.new(table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    on_exit(fn ->
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    %{table: table}
  end

  test "allows requests under the limit" do
    user_id = Ecto.UUID.generate()
    model_id = "test-model"

    for _ <- 1..5 do
      assert :ok = TokenBucket.check_rate(user_id, model_id, limit: 10, window_ms: 60_000)
    end
  end

  test "rejects requests over the limit" do
    user_id = Ecto.UUID.generate()
    model_id = "test-model"

    # Exhaust the limit
    for _ <- 1..3 do
      assert :ok = TokenBucket.check_rate(user_id, model_id, limit: 3, window_ms: 60_000)
    end

    # Next request should be rejected
    assert {:error, :rate_limited, remaining_ms} =
             TokenBucket.check_rate(user_id, model_id, limit: 3, window_ms: 60_000)

    assert is_integer(remaining_ms)
    assert remaining_ms > 0
  end

  test "different users have separate counters" do
    user_a = Ecto.UUID.generate()
    user_b = Ecto.UUID.generate()
    model_id = "test-model"

    # Exhaust user_a's limit
    for _ <- 1..2 do
      TokenBucket.check_rate(user_a, model_id, limit: 2, window_ms: 60_000)
    end

    assert {:error, :rate_limited, _} =
             TokenBucket.check_rate(user_a, model_id, limit: 2, window_ms: 60_000)

    # user_b should still be allowed
    assert :ok = TokenBucket.check_rate(user_b, model_id, limit: 2, window_ms: 60_000)
  end

  test "different models have separate counters" do
    user_id = Ecto.UUID.generate()

    for _ <- 1..2 do
      TokenBucket.check_rate(user_id, "model-a", limit: 2, window_ms: 60_000)
    end

    assert {:error, :rate_limited, _} =
             TokenBucket.check_rate(user_id, "model-a", limit: 2, window_ms: 60_000)

    assert :ok = TokenBucket.check_rate(user_id, "model-b", limit: 2, window_ms: 60_000)
  end

  test "sweep_stale removes old entries" do
    # Insert a request to create an ETS entry, then sweep with max_age_ms=0
    # to mark everything as stale
    user_id = Ecto.UUID.generate()
    assert :ok = TokenBucket.check_rate(user_id, "sweep-model", limit: 10, window_ms: 60_000)

    # Sweep with 0 age - everything is stale
    deleted = TokenBucket.sweep_stale(0)
    assert is_integer(deleted)
    assert deleted >= 1

    # The entry was removed, so this user can make requests again from count=1
    assert :ok = TokenBucket.check_rate(user_id, "sweep-model", limit: 1, window_ms: 60_000)
  end
end
