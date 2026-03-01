defmodule Liteskill.Chat.StreamRegistry do
  @moduledoc """
  GenServer-backed registry tracking active LLM stream tasks per conversation.

  Each entry maps `conversation_id → task_pid` in an ETS table for fast
  concurrent reads (`lookup/1`, `streaming?/1`). The GenServer owns monitors
  so entries are automatically cleaned up when the task exits.

  When a stream task dies, recovery is scheduled after a configurable delay
  and dispatched via `Task.Supervisor` to consolidate partial content and
  transition the conversation back to `:active` state. This makes stream
  lifecycle fully backend-managed — the frontend is a pure observer.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @default_recovery_delay_ms 250
  @max_recovery_retries 3

  # --- Public API ---

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a stream task for the given conversation.

  The GenServer monitors the pid and auto-cleans the ETS entry on exit.
  """
  def register(conversation_id, pid, opts \\ []) when is_pid(pid) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:register, conversation_id, pid})
  end

  @doc """
  Looks up the active stream task for a conversation.

  Returns `{:ok, pid}` if found and the process is alive, `:error` otherwise.
  Reads directly from ETS — no GenServer call needed.
  """
  def lookup(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, pid}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      [] ->
        :error
    end
  rescue
    # coveralls-ignore-next-line
    ArgumentError -> :error
  end

  @doc """
  Returns `true` if a stream task is registered and alive for the conversation.
  """
  def streaming?(conversation_id) do
    match?({:ok, _}, lookup(conversation_id))
  end

  @doc """
  Manually removes a conversation from the registry.
  """
  def unregister(conversation_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:unregister, conversation_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Create the ETS table (or reuse if it already exists)
    try do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    rescue
      ArgumentError -> :ok
    end

    recovery_delay_ms = Keyword.get(opts, :recovery_delay_ms, @default_recovery_delay_ms)

    {:ok, %{monitors: %{}, recovery_delay_ms: recovery_delay_ms}}
  end

  @impl true
  def handle_call({:register, conversation_id, pid}, _from, state) do
    :ets.insert(@table, {conversation_id, pid})
    ref = Process.monitor(pid)

    monitors = Map.put(state.monitors, ref, {conversation_id, pid})
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unregister, conversation_id}, _from, state) do
    :ets.delete(@table, conversation_id)

    # Find and demonitor any monitor for this conversation
    {ref_to_remove, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn
        {ref, {conv_id, _pid}}, {_found, acc} when conv_id == conversation_id ->
          Process.demonitor(ref, [:flush])
          {ref, Map.delete(acc, ref)}

        _, acc ->
          acc
      end)

    _ = ref_to_remove
    {:reply, :ok, %{state | monitors: monitors}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{conv_id, ^pid}, monitors} ->
        # Only delete if the ETS entry still points to this pid
        # (protects against double-registration where a newer pid replaced it)
        try do
          :ets.delete_object(@table, {conv_id, pid})
        rescue
          # coveralls-ignore-next-line
          ArgumentError -> :ok
        end

        Process.send_after(self(), {:recover, conv_id, 0}, state.recovery_delay_ms)
        {:noreply, %{state | monitors: monitors}}

      {nil, _} ->
        # Monitor ref not found — already demonitored via unregister
        {:noreply, state}
    end
  end

  def handle_info({:recover, conv_id, attempt}, state) do
    # Skip recovery if a new stream task has already registered for this
    # conversation. Without this guard, the delayed recovery would fail_stream
    # the *new* stream's message, not the old one that crashed.
    if streaming?(conv_id) do
      Logger.debug("StreamRegistry: skipping recovery for #{conv_id} — new stream active")
    else
      recovery_delay = state.recovery_delay_ms

      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        try do
          Liteskill.Chat.recover_stream_by_id(conv_id)
        rescue
          # coveralls-ignore-start — rescue runs inside async Task.Supervisor child
          e in [
            Ecto.NoResultsError,
            Postgrex.Error,
            DBConnection.ConnectionError,
            Ecto.ConstraintError,
            Ecto.StaleEntryError,
            Ecto.InvalidChangesetError
          ] ->
            if attempt < @max_recovery_retries do
              backoff = recovery_delay * Integer.pow(2, attempt)

              Logger.warning(
                "StreamRegistry auto-recovery failed for #{conv_id} " <>
                  "(attempt #{attempt + 1}/#{@max_recovery_retries + 1}): #{Exception.message(e)}, " <>
                  "retrying in #{backoff}ms"
              )

              Process.send_after(
                Process.whereis(__MODULE__),
                {:recover, conv_id, attempt + 1},
                backoff
              )
            else
              Logger.error(
                "StreamRegistry auto-recovery exhausted for #{conv_id} " <>
                  "after #{attempt + 1} attempts: #{Exception.message(e)}"
              )
            end

            # coveralls-ignore-stop
        end
      end)
    end

    {:noreply, state}
  end
end
