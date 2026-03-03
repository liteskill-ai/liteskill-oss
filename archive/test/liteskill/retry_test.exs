defmodule Liteskill.RetryTest do
  use ExUnit.Case, async: true

  alias Liteskill.Retry

  describe "calculate_backoff/3" do
    test "returns value in expected range for attempt 0" do
      backoff = Retry.calculate_backoff(1000, 0)
      # base * 2^0 * (1 + jitter) where jitter in (0, 1)
      assert backoff >= 1000
      assert backoff <= 2000
    end

    test "doubles with each attempt" do
      # Attempt 2: base * 4 * (1 + jitter), so minimum is 4000
      backoff = Retry.calculate_backoff(1000, 2)
      assert backoff >= 4000
      assert backoff <= 8000
    end

    test "applies 3x multiplier when rate_limited: true" do
      backoff = Retry.calculate_backoff(1000, 0, rate_limited: true)
      # 3000 * 1 * (1 + jitter)
      assert backoff >= 3000
      assert backoff <= 6000
    end

    test "returns 0 range for base_ms of 0" do
      assert Retry.calculate_backoff(0, 5) == 0
    end
  end

  describe "interruptible_sleep/1" do
    test "returns :ok after sleeping" do
      assert Retry.interruptible_sleep(1) == :ok
    end

    test "returns :cancelled when cancel message is received" do
      send(self(), :cancel)
      assert Retry.interruptible_sleep(10_000) == :cancelled
    end
  end
end
