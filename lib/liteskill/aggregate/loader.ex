defmodule Liteskill.Aggregate.Loader do
  @moduledoc """
  Stateless aggregate loader.

  Loads aggregate state by reading events from the event store (with optional
  snapshot support), and executes commands by loading state, handling the command,
  and appending resulting events.
  """

  alias Liteskill.EventStore.Postgres, as: Store

  @snapshot_interval 100

  @doc """
  Loads the current state of an aggregate from the event store.

  If a snapshot exists, loads from the snapshot version forward.
  Otherwise replays all events from the beginning.
  """
  def load(aggregate_module, stream_id) do
    {state, version} =
      case Store.get_latest_snapshot(stream_id) do
        {:ok, snapshot} ->
          base = Map.from_struct(aggregate_module.init())
          restored = Map.merge(base, atomize_keys(snapshot.data))
          restored = restore_atom_fields(restored)
          state = struct(aggregate_module, restored)
          {state, snapshot.stream_version}

        {:error, :not_found} ->
          {aggregate_module.init(), 0}
      end

    events = Store.read_stream_forward(stream_id, version + 1, 10_000)

    final_state =
      Enum.reduce(events, state, fn event, acc ->
        aggregate_module.apply_event(acc, event)
      end)

    current_version = if events == [], do: version, else: List.last(events).stream_version
    {final_state, current_version}
  end

  @doc """
  Executes a command against an aggregate.

  Loads the aggregate state, handles the command, and appends
  resulting events to the event store. Returns the updated state
  and new events on success.
  """
  def execute(aggregate_module, stream_id, command) do
    do_execute(aggregate_module, stream_id, command, 0)
  end

  # coveralls-ignore-start
  defp do_execute(_aggregate_module, _stream_id, _command, 3) do
    {:error, :wrong_expected_version}
  end

  # coveralls-ignore-stop

  defp do_execute(aggregate_module, stream_id, command, attempt) do
    {state, version} = load(aggregate_module, stream_id)

    case aggregate_module.handle_command(state, command) do
      {:ok, events_data} when events_data == [] ->
        {:ok, state, []}

      {:ok, events_data} ->
        case Store.append_events(stream_id, version, events_data) do
          {:ok, stored_events} ->
            new_state =
              Enum.reduce(stored_events, state, fn event, acc ->
                aggregate_module.apply_event(acc, event)
              end)

            new_version = List.last(stored_events).stream_version
            maybe_snapshot(aggregate_module, stream_id, new_state, version, new_version)

            {:ok, new_state, stored_events}

          {:error, :wrong_expected_version} ->
            # coveralls-ignore-next-line - requires true concurrent writes between load and append
            do_execute(aggregate_module, stream_id, command, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_snapshot(aggregate_module, stream_id, state, old_version, new_version) do
    # Save snapshot when we cross a @snapshot_interval boundary
    old_bucket = div(old_version, @snapshot_interval)
    new_bucket = div(new_version, @snapshot_interval)

    if new_bucket > old_bucket do
      snapshot_type = aggregate_module |> Module.split() |> List.last()
      data = state |> Map.from_struct() |> stringify_keys()
      Store.save_snapshot(stream_id, new_version, snapshot_type, data)
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            # coveralls-ignore-next-line
            ArgumentError -> key
          end

        {atom_key, atomize_value(value)}

      # coveralls-ignore-next-line
      {key, value} ->
        {key, atomize_value(value)}
    end)
  end

  defp atomize_value(map) when is_map(map), do: atomize_keys(map)
  defp atomize_value(list) when is_list(list), do: Enum.map(list, &atomize_value/1)
  defp atomize_value(value), do: value

  # Atom fields (like :status) lose their type through JSONB round-trip.
  # Convert known string values back to atoms using existing atoms only.
  defp restore_atom_fields(%{status: status} = map) when is_binary(status) do
    atom =
      try do
        String.to_existing_atom(status)
      rescue
        # coveralls-ignore-next-line
        ArgumentError -> status
      end

    if is_atom(atom) do
      %{map | status: atom}
    else
      # coveralls-ignore-next-line
      map
    end
  end

  defp restore_atom_fields(map), do: map
end
