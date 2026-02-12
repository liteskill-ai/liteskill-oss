defmodule Liteskill.Aggregate.LoaderTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Aggregate.Loader
  alias Liteskill.EventStore.Postgres, as: Store

  defmodule Counter do
    @behaviour Liteskill.Aggregate

    defstruct count: 0

    @impl true
    def init, do: %__MODULE__{}

    @impl true
    def apply_event(state, %{event_type: "CounterIncremented", data: %{"amount" => amount}}) do
      %{state | count: state.count + amount}
    end

    @impl true
    def handle_command(%{count: _count}, {:increment, %{amount: amount}}) when amount > 0 do
      {:ok, [%{event_type: "CounterIncremented", data: %{"amount" => amount}}]}
    end

    def handle_command(_state, {:increment, _params}) do
      {:error, :invalid_amount}
    end

    def handle_command(_state, {:noop, _params}) do
      {:ok, []}
    end
  end

  describe "load/2" do
    test "returns initial state for empty stream" do
      {state, version} = Loader.load(Counter, stream_id())
      assert state == %Counter{count: 0}
      assert version == 0
    end

    test "replays events into state" do
      stream = stream_id()

      Store.append_events(stream, 0, [
        %{event_type: "CounterIncremented", data: %{"amount" => 3}},
        %{event_type: "CounterIncremented", data: %{"amount" => 7}}
      ])

      {state, version} = Loader.load(Counter, stream)
      assert state.count == 10
      assert version == 2
    end

    test "loads from snapshot when available" do
      stream = stream_id()

      Store.append_events(stream, 0, [
        %{event_type: "CounterIncremented", data: %{"amount" => 5}},
        %{event_type: "CounterIncremented", data: %{"amount" => 10}}
      ])

      Store.save_snapshot(stream, 2, "Counter", %{"count" => 15})

      Store.append_events(stream, 2, [
        %{event_type: "CounterIncremented", data: %{"amount" => 3}}
      ])

      {state, version} = Loader.load(Counter, stream)
      assert state.count == 18
      assert version == 3
    end
  end

  describe "execute/3" do
    test "executes a command and appends events" do
      stream = stream_id()
      {:ok, state, events} = Loader.execute(Counter, stream, {:increment, %{amount: 5}})

      assert state.count == 5
      assert length(events) == 1
      assert Enum.at(events, 0).stream_version == 1
    end

    test "sequential executions maintain version" do
      stream = stream_id()
      {:ok, _, _} = Loader.execute(Counter, stream, {:increment, %{amount: 3}})
      {:ok, state, events} = Loader.execute(Counter, stream, {:increment, %{amount: 7}})

      assert state.count == 10
      assert Enum.at(events, 0).stream_version == 2
    end

    test "returns error for invalid command" do
      assert {:error, :invalid_amount} =
               Loader.execute(Counter, stream_id(), {:increment, %{amount: -1}})
    end

    test "handles empty event list from command" do
      stream = stream_id()
      {:ok, state, events} = Loader.execute(Counter, stream, {:noop, %{}})

      assert state.count == 0
      assert events == []
    end

    test "retries on concurrent modification and succeeds" do
      stream = stream_id()

      # Execute first command to establish version 1
      {:ok, _, _} = Loader.execute(Counter, stream, {:increment, %{amount: 1}})

      # Simulate a concurrent modification by directly appending an event
      # The loader will reload and retry on wrong_expected_version
      Store.append_events(stream, 1, [
        %{event_type: "CounterIncremented", data: %{"amount" => 100}}
      ])

      # Execute should succeed after retry — loads fresh state at version 2
      {:ok, state, _events} = Loader.execute(Counter, stream, {:increment, %{amount: 5}})
      assert state.count == 106
    end
  end

  describe "automatic snapshotting" do
    test "saves snapshot when crossing 100-event boundary" do
      stream = stream_id()

      # Append 99 events (versions 1..99)
      events = for _i <- 1..99, do: %{event_type: "CounterIncremented", data: %{"amount" => 1}}
      {:ok, _} = Store.append_events(stream, 0, events)

      # The 100th event should trigger a snapshot
      {:ok, state, _events} = Loader.execute(Counter, stream, {:increment, %{amount: 1}})
      assert state.count == 100

      {:ok, snapshot} = Store.get_latest_snapshot(stream)
      assert snapshot.stream_version == 100
      assert snapshot.data["count"] == 100
    end

    test "does not save snapshot before reaching interval" do
      stream = stream_id()

      {:ok, _state, _events} = Loader.execute(Counter, stream, {:increment, %{amount: 5}})

      assert {:error, :not_found} = Store.get_latest_snapshot(stream)
    end

    test "loads from snapshot after snapshotting" do
      stream = stream_id()

      # Create 99 events then the 100th via execute
      events = for _i <- 1..99, do: %{event_type: "CounterIncremented", data: %{"amount" => 1}}
      {:ok, _} = Store.append_events(stream, 0, events)
      {:ok, _, _} = Loader.execute(Counter, stream, {:increment, %{amount: 1}})

      # Add one more event after snapshot
      {:ok, state, _} = Loader.execute(Counter, stream, {:increment, %{amount: 10}})
      assert state.count == 110

      # Load should use snapshot + 1 event
      {loaded_state, version} = Loader.load(Counter, stream)
      assert loaded_state.count == 110
      assert version == 101
    end
  end

  defp stream_id, do: "test-counter-#{System.unique_integer([:positive])}"
end
