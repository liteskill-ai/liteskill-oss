defmodule Liteskill.Aggregate.Loader do
  @moduledoc """
  Stateless aggregate loader.

  Loads aggregate state by reading events from the event store (with optional
  snapshot support), and executes commands by loading state, handling the command,
  and appending resulting events.
  """

  alias Liteskill.EventStore.Postgres, as: Store

  require Logger

  @snapshot_interval 100
  @replay_batch_size 10_000
  @max_total_replay 100_000

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

    events = read_all_events_forward(stream_id, version + 1)

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

  # --- Event Replay ---

  # Paginates through events in batches to avoid silently truncating
  # large streams. Emits a warning if the stream exceeds @max_total_replay.
  defp read_all_events_forward(stream_id, from_version) do
    do_read_all(stream_id, from_version, [], 0)
  end

  defp do_read_all(stream_id, from_version, acc, total) do
    batch = Store.read_stream_forward(stream_id, from_version, @replay_batch_size)
    new_total = total + length(batch)
    all = acc ++ batch

    cond do
      length(batch) < @replay_batch_size ->
        all

      # coveralls-ignore-start
      new_total >= @max_total_replay ->
        Logger.error(
          "Aggregate replay hit #{@max_total_replay} event cap: stream=#{stream_id} " <>
            "— snapshots may be failing. Loaded #{new_total} events."
        )

        :telemetry.execute(
          [:liteskill, :aggregate, :replay_cap_hit],
          %{count: new_total},
          %{stream_id: stream_id}
        )

        all

      # coveralls-ignore-stop

      # coveralls-ignore-start - requires >10k events in a single batch to reach
      true ->
        next_from = List.last(batch).stream_version + 1
        do_read_all(stream_id, next_from, all, new_total)
        # coveralls-ignore-stop
    end
  end

  # --- Snapshots ---

  defp maybe_snapshot(aggregate_module, stream_id, state, old_version, new_version) do
    # Save snapshot when we cross a @snapshot_interval boundary
    old_bucket = div(old_version, @snapshot_interval)
    new_bucket = div(new_version, @snapshot_interval)

    if new_bucket > old_bucket do
      snapshot_type = aggregate_module |> Module.split() |> List.last()
      data = state |> Map.from_struct() |> stringify_keys()

      case Store.save_snapshot(stream_id, new_version, snapshot_type, data) do
        {:ok, _} ->
          prune_old_snapshots(stream_id, new_version)

        # coveralls-ignore-start
        {:error, reason} ->
          Logger.error(
            "Failed to save snapshot: stream=#{stream_id} version=#{new_version} " <>
              "reason=#{inspect(reason)}"
          )

          :telemetry.execute(
            [:liteskill, :aggregate, :snapshot_failed],
            %{count: 1},
            %{stream_id: stream_id, version: new_version}
          )

          # coveralls-ignore-stop
      end
    end
  rescue
    # coveralls-ignore-start
    e ->
      Logger.error(
        "Snapshot save raised: stream=#{stream_id} version=#{new_version} " <>
          "error=#{Exception.message(e)}"
      )

      :telemetry.execute(
        [:liteskill, :aggregate, :snapshot_failed],
        %{count: 1},
        %{stream_id: stream_id, version: new_version}
      )

      # coveralls-ignore-stop
  end

  defp prune_old_snapshots(stream_id, current_version) do
    Store.delete_snapshots_before(stream_id, current_version)
  rescue
    # coveralls-ignore-start
    e ->
      Logger.warning("Failed to prune old snapshots: stream=#{stream_id} error=#{Exception.message(e)}")

      # coveralls-ignore-stop
  end

  # --- Key Conversion ---

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  # coveralls-ignore-start - exercised via Events.serialize tests; Loader snapshot
  # path uses Counter (flat struct) so nested branches are not hit in loader tests.
  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  # coveralls-ignore-stop
  defp stringify_value(value), do: value

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
  # Also restores nested atom values in current_stream.tool_calls[].status.
  defp restore_atom_fields(%{status: status} = map) when is_binary(status) do
    map = safe_to_atom(map, :status, status)
    restore_nested_atom_fields(map)
  end

  defp restore_atom_fields(map), do: restore_nested_atom_fields(map)

  defp restore_nested_atom_fields(%{current_stream: %{tool_calls: tool_calls} = stream} = map) when is_list(tool_calls) do
    restored_tcs =
      Enum.map(tool_calls, fn
        %{status: status} = tc when is_binary(status) -> safe_to_atom(tc, :status, status)
        tc -> tc
      end)

    %{map | current_stream: %{stream | tool_calls: restored_tcs}}
  end

  defp restore_nested_atom_fields(map), do: map

  defp safe_to_atom(map, key, value) do
    atom =
      try do
        String.to_existing_atom(value)
      rescue
        # coveralls-ignore-next-line
        ArgumentError -> value
      end

    if is_atom(atom), do: %{map | key => atom}, else: map
  end
end
