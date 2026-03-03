defmodule Liteskill.Aggregate.LoaderTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Aggregate.Loader
  alias Liteskill.EventStore.Postgres, as: Store

  defmodule Counter do
    @moduledoc false
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

  describe "snapshot with nested data and atom fields" do
    defmodule StatefulAggregate do
      @moduledoc false
      @behaviour Liteskill.Aggregate

      defstruct status: :created, items: [], metadata: %{}

      @impl true
      def init, do: %__MODULE__{}

      @impl true
      def apply_event(state, %{event_type: "ItemAdded", data: %{"item" => item}}) do
        %{state | status: :active, items: state.items ++ [item]}
      end

      def apply_event(state, %{event_type: "MetadataSet", data: %{"metadata" => meta}}) do
        %{state | metadata: meta}
      end

      @impl true
      def handle_command(_state, {:add_item, %{item: item}}) do
        {:ok, [%{event_type: "ItemAdded", data: %{"item" => item}}]}
      end

      def handle_command(_state, {:set_metadata, %{metadata: meta}}) do
        {:ok, [%{event_type: "MetadataSet", data: %{"metadata" => meta}}]}
      end
    end

    test "restores atom status and nested data from snapshot" do
      stream = stream_id()

      # Save a snapshot with stringified keys, nested map, list values, and atom status as string
      Store.save_snapshot(stream, 5, "StatefulAggregate", %{
        "status" => "active",
        "items" => ["one", "two"],
        "metadata" => %{"key" => "value", "nested" => %{"deep" => true}}
      })

      {state, version} = Loader.load(StatefulAggregate, stream)
      assert version == 5
      assert state.status == :active
      assert state.items == ["one", "two"]
      assert state.metadata == %{key: "value", nested: %{deep: true}}
    end
  end

  describe "snapshot with streaming state and tool_calls" do
    defmodule StreamingAggregate do
      @moduledoc false
      @behaviour Liteskill.Aggregate

      defstruct status: :created, current_stream: nil

      @impl true
      def init, do: %__MODULE__{}

      @impl true
      def apply_event(state, _event), do: state

      @impl true
      def handle_command(_state, _command), do: {:ok, []}
    end

    test "restores tool_call status atoms from snapshot" do
      stream = stream_id()

      Store.save_snapshot(stream, 10, "StreamingAggregate", %{
        "status" => "streaming",
        "current_stream" => %{
          "message_id" => "msg-1",
          "tool_calls" => [
            %{
              "tool_use_id" => "tu-1",
              "tool_name" => "test",
              "input" => %{},
              "status" => "started"
            },
            %{
              "tool_use_id" => "tu-2",
              "tool_name" => "test2",
              "input" => %{},
              "status" => "completed"
            },
            %{"tool_use_id" => "tu-3", "tool_name" => "test3", "input" => %{}}
          ]
        }
      })

      {state, version} = Loader.load(StreamingAggregate, stream)
      assert version == 10
      assert state.status == :streaming
      assert state.current_stream

      tcs = state.current_stream.tool_calls
      assert length(tcs) == 3
      assert Enum.at(tcs, 0).status == :started
      assert Enum.at(tcs, 1).status == :completed
      # Third tool_call has no status — exercises the catch-all branch
      refute Map.has_key?(Enum.at(tcs, 2), :status)
    end
  end

  describe "snapshot pruning" do
    test "old snapshots are deleted after saving a new one" do
      stream = stream_id()

      # Manually create snapshots at version 100 and 200
      Store.save_snapshot(stream, 100, "Counter", %{"count" => 100})
      Store.save_snapshot(stream, 200, "Counter", %{"count" => 200})

      # Verify both exist
      {:ok, snapshot} = Store.get_latest_snapshot(stream)
      assert snapshot.stream_version == 200

      # Append 300 events then trigger a third snapshot via execute
      events = for _i <- 1..299, do: %{event_type: "CounterIncremented", data: %{"amount" => 1}}
      {:ok, _} = Store.append_events(stream, 0, events)
      {:ok, state, _} = Loader.execute(Counter, stream, {:increment, %{amount: 1}})
      assert state.count == 300

      # A new snapshot at version 300 should exist, and older ones pruned
      {:ok, snapshot} = Store.get_latest_snapshot(stream)
      assert snapshot.stream_version == 300

      # Old snapshots should be gone (delete_snapshots_before removes versions < 300)
      deleted = Store.delete_snapshots_before(stream, 300)
      assert deleted == 0
    end
  end

  describe "recursive stringify_keys for snapshots" do
    defmodule NestedAggregate do
      @moduledoc false
      @behaviour Liteskill.Aggregate

      defstruct status: :created, config: %{}, items: []

      @impl true
      def init, do: %__MODULE__{}

      @impl true
      def apply_event(state, %{event_type: "Configured", data: %{"config" => config}}) do
        %{state | status: :active, config: config}
      end

      @impl true
      def handle_command(_state, {:configure, %{config: config}}) do
        {:ok, [%{event_type: "Configured", data: %{"config" => config}}]}
      end
    end

    test "nested map keys in snapshots survive round-trip" do
      stream = stream_id()

      # Save a snapshot with nested maps (simulating what the loader produces)
      Store.save_snapshot(stream, 5, "NestedAggregate", %{
        "status" => "active",
        "config" => %{"nested" => %{"deep_key" => "deep_value"}},
        "items" => [%{"name" => "item1"}]
      })

      {state, version} = Loader.load(NestedAggregate, stream)
      assert version == 5
      assert state.status == :active
      assert state.config == %{nested: %{deep_key: "deep_value"}}
      assert state.items == [%{name: "item1"}]
    end
  end

  defp stream_id, do: "test-counter-#{System.unique_integer([:positive])}"
end
