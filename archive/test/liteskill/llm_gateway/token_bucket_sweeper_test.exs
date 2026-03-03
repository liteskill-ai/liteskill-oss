defmodule Liteskill.LlmGateway.TokenBucket.SweeperTest do
  use ExUnit.Case, async: true

  alias Liteskill.LlmGateway.TokenBucket.Sweeper

  describe "GenServer lifecycle" do
    test "starts and responds to :sweep" do
      pid =
        start_supervised!({Sweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 600_000})

      send(pid, :sweep)
      state = :sys.get_state(pid)

      assert state.interval == 600_000
      assert Process.alive?(pid)
    end

    test "ignores unknown messages" do
      pid =
        start_supervised!({Sweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 600_000})

      send(pid, :unknown_message)
      _ = :sys.get_state(pid)

      assert Process.alive?(pid)
    end

    test "schedules periodic sweeps" do
      pid =
        start_supervised!({Sweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 50})

      # Wait for at least one sweep cycle
      Process.sleep(100)
      state = :sys.get_state(pid)

      assert state.interval == 50
      assert Process.alive?(pid)
    end
  end
end
