defmodule Liteskill.EventStore.PostgresTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.EventStore.Postgres

  describe "append_events/3" do
    test "appends events to a new stream" do
      events = [
        %{event_type: "TestEvent", data: %{"key" => "value1"}},
        %{event_type: "TestEvent", data: %{"key" => "value2"}}
      ]

      assert {:ok, stored} = Postgres.append_events(stream_id(), 0, events)
      assert length(stored) == 2
      assert Enum.at(stored, 0).stream_version == 1
      assert Enum.at(stored, 1).stream_version == 2
      assert Enum.at(stored, 0).data == %{"key" => "value1"}
    end

    test "appends events with correct expected version" do
      stream = stream_id()
      {:ok, _} = Postgres.append_events(stream, 0, [event()])
      {:ok, stored} = Postgres.append_events(stream, 1, [event("second")])

      assert length(stored) == 1
      assert Enum.at(stored, 0).stream_version == 2
    end

    test "returns error on wrong expected version" do
      stream = stream_id()
      {:ok, _} = Postgres.append_events(stream, 0, [event()])

      assert {:error, :wrong_expected_version} =
               Postgres.append_events(stream, 0, [event("conflict")])
    end

    test "stores metadata" do
      events = [%{event_type: "TestEvent", data: %{"a" => 1}, metadata: %{"user_id" => "u1"}}]
      {:ok, [stored]} = Postgres.append_events(stream_id(), 0, events)

      assert stored.metadata == %{"user_id" => "u1"}
    end
  end

  describe "read_stream_forward/1" do
    test "returns events in version order" do
      stream = stream_id()
      {:ok, _} = Postgres.append_events(stream, 0, [event("first"), event("second")])

      events = Postgres.read_stream_forward(stream)
      assert length(events) == 2
      assert Enum.at(events, 0).stream_version == 1
      assert Enum.at(events, 1).stream_version == 2
    end

    test "returns empty list for unknown stream" do
      assert Postgres.read_stream_forward("nonexistent-stream") == []
    end
  end

  describe "read_stream_forward/3" do
    test "returns events from a given version with limit" do
      stream = stream_id()
      events = Enum.map(1..5, fn i -> event("event-#{i}") end)
      {:ok, _} = Postgres.append_events(stream, 0, events)

      result = Postgres.read_stream_forward(stream, 3, 2)
      assert length(result) == 2
      assert Enum.at(result, 0).stream_version == 3
      assert Enum.at(result, 1).stream_version == 4
    end
  end

  describe "stream_version/1" do
    test "returns 0 for empty stream" do
      assert Postgres.stream_version("nonexistent") == 0
    end

    test "returns latest version" do
      stream = stream_id()
      {:ok, _} = Postgres.append_events(stream, 0, [event(), event()])

      assert Postgres.stream_version(stream) == 2
    end
  end

  describe "subscribe/1" do
    test "receives events after subscribing" do
      stream = stream_id()
      Postgres.subscribe(stream)

      {:ok, _} = Postgres.append_events(stream, 0, [event("subscribed")])

      assert_receive {:events, ^stream, [stored_event]}
      assert stored_event.data["key"] == "subscribed"
    end
  end

  describe "snapshots" do
    test "save and retrieve snapshot" do
      stream = stream_id()
      data = %{"status" => "active", "count" => 5}

      assert {:ok, _} = Postgres.save_snapshot(stream, 5, "TestAggregate", data)
      assert {:ok, snapshot} = Postgres.get_latest_snapshot(stream)
      assert snapshot.stream_version == 5
      assert snapshot.data == data
    end

    test "get_latest_snapshot returns latest by version" do
      stream = stream_id()
      {:ok, _} = Postgres.save_snapshot(stream, 3, "TestAggregate", %{"v" => 3})
      {:ok, _} = Postgres.save_snapshot(stream, 7, "TestAggregate", %{"v" => 7})

      assert {:ok, snapshot} = Postgres.get_latest_snapshot(stream)
      assert snapshot.stream_version == 7
      assert snapshot.data == %{"v" => 7}
    end

    test "get_latest_snapshot returns error for unknown stream" do
      assert {:error, :not_found} = Postgres.get_latest_snapshot("no-such-stream")
    end
  end

  describe "delete_snapshots_before/2" do
    test "deletes snapshots before a given version" do
      stream = stream_id()
      {:ok, _} = Postgres.save_snapshot(stream, 100, "TestAggregate", %{"v" => 100})
      {:ok, _} = Postgres.save_snapshot(stream, 200, "TestAggregate", %{"v" => 200})
      {:ok, _} = Postgres.save_snapshot(stream, 300, "TestAggregate", %{"v" => 300})

      deleted = Postgres.delete_snapshots_before(stream, 300)
      assert deleted == 2

      # Only version 300 should remain
      {:ok, snapshot} = Postgres.get_latest_snapshot(stream)
      assert snapshot.stream_version == 300
    end

    test "returns 0 when no snapshots to delete" do
      assert Postgres.delete_snapshots_before("no-such-stream", 100) == 0
    end

    test "does not delete snapshots for other streams" do
      stream_a = stream_id()
      stream_b = stream_id()
      {:ok, _} = Postgres.save_snapshot(stream_a, 100, "TestAggregate", %{"v" => 100})
      {:ok, _} = Postgres.save_snapshot(stream_b, 100, "TestAggregate", %{"v" => 100})

      Postgres.delete_snapshots_before(stream_a, 200)

      # stream_b's snapshot should still exist
      {:ok, snapshot} = Postgres.get_latest_snapshot(stream_b)
      assert snapshot.stream_version == 100
    end
  end

  defp stream_id, do: "test-stream-#{System.unique_integer([:positive])}"

  defp event(key \\ "default") do
    %{event_type: "TestEvent", data: %{"key" => key}}
  end
end
