defmodule Liteskill.EventStore.Postgres do
  @moduledoc """
  PostgreSQL implementation of the EventStore behaviour.

  Uses optimistic concurrency via a unique index on `(stream_id, stream_version)`.
  Broadcasts events via Phoenix.PubSub after successful appends.
  """

  @behaviour Liteskill.EventStore

  import Ecto.Query

  alias Liteskill.EventStore.Event
  alias Liteskill.EventStore.Snapshot
  alias Liteskill.Repo

  @pubsub Liteskill.PubSub
  @topic_prefix "event_store:"

  @impl true
  def append_events(stream_id, expected_version, events_data) do
    result =
      Repo.transaction(fn ->
        events_data
        |> Enum.with_index(expected_version + 1)
        |> Enum.map(fn {event_data, version} ->
          Repo.insert!(%Event{
            stream_id: stream_id,
            stream_version: version,
            event_type: Map.fetch!(event_data, :event_type),
            data: Map.fetch!(event_data, :data),
            metadata: Map.get(event_data, :metadata, %{})
          })
        end)
      end)

    case result do
      {:ok, events} ->
        broadcast_events(stream_id, events)
        {:ok, events}

      # coveralls-ignore-start
      {:error, _} = error ->
        error
        # coveralls-ignore-stop
    end
  rescue
    _e in [Ecto.ConstraintError] ->
      {:error, :wrong_expected_version}

    # coveralls-ignore-start
    e in [Postgrex.Error] ->
      if e.postgres[:code] == :unique_violation do
        {:error, :wrong_expected_version}
      else
        reraise e, __STACKTRACE__
      end

      # coveralls-ignore-stop
  end

  @impl true
  def read_stream_forward(stream_id) do
    Event
    |> where([e], e.stream_id == ^stream_id)
    |> order_by([e], asc: e.stream_version)
    |> Repo.all()
  end

  @impl true
  def read_stream_forward(stream_id, from_version, max_count) do
    Event
    |> where([e], e.stream_id == ^stream_id and e.stream_version >= ^from_version)
    |> order_by([e], asc: e.stream_version)
    |> limit(^max_count)
    |> Repo.all()
  end

  @impl true
  def stream_version(stream_id) do
    Event
    |> where([e], e.stream_id == ^stream_id)
    |> select([e], max(e.stream_version))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @impl true
  def subscribe(stream_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(stream_id))
  end

  @impl true
  def save_snapshot(stream_id, stream_version, snapshot_type, data) do
    Repo.insert(%Snapshot{stream_id: stream_id, stream_version: stream_version, snapshot_type: snapshot_type, data: data})
  end

  @impl true
  def get_latest_snapshot(stream_id) do
    snapshot =
      Snapshot
      |> where([s], s.stream_id == ^stream_id)
      |> order_by([s], desc: s.stream_version)
      |> limit(1)
      |> Repo.one()

    case snapshot do
      nil -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  @impl true
  def delete_snapshots_before(stream_id, version) do
    {count, _} =
      Snapshot
      |> where([s], s.stream_id == ^stream_id and s.stream_version < ^version)
      |> Repo.delete_all()

    count
  end

  defp broadcast_events(stream_id, events) do
    Phoenix.PubSub.broadcast(@pubsub, topic(stream_id), {:events, stream_id, events})
  end

  defp topic(stream_id), do: @topic_prefix <> stream_id
end
