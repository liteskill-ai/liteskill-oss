defmodule Liteskill.Chat.Projector do
  @moduledoc """
  GenServer that subscribes to PubSub event broadcasts and updates
  projection tables (conversations, messages, chunks, tool_calls).

  Also supports `rebuild_projections/0` to replay all events from scratch.
  """

  use GenServer

  import Ecto.Query

  alias Liteskill.Chat.Conversation
  alias Liteskill.Chat.Message
  alias Liteskill.Chat.MessageChunk
  alias Liteskill.Chat.ToolCall
  alias Liteskill.EventStore.Event
  alias Liteskill.Repo

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def project_events(stream_id, events) do
    GenServer.call(__MODULE__, {:project_events, stream_id, events}, 30_000)
  end

  @doc """
  Asynchronously projects events. Use when the caller does not need to
  query projected data immediately (e.g. streaming chunk projections).
  """
  def project_events_async(stream_id, events) do
    GenServer.cast(__MODULE__, {:project_events, stream_id, events})
  end

  @doc """
  Synchronous no-op. Returns when the Projector has drained all preceding messages.
  """
  def sync do
    GenServer.call(__MODULE__, :sync, 30_000)
  end

  def rebuild_projections do
    GenServer.call(__MODULE__, :rebuild, :infinity)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:project_events, stream_id, events}, _from, state) do
    do_project(stream_id, events)
    broadcast_projected(stream_id, events)
    {:reply, :ok, state}
  end

  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:rebuild, _from, state) do
    result = do_rebuild()
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:project_events, stream_id, events}, state) do
    do_project(stream_id, events)
    {:noreply, state}
  end

  # coveralls-ignore-start - only reached on transient DB errors triggering async retry
  @impl true
  def handle_info({:retry_projection_batch, stream_id, events, attempt}, state) do
    do_project_ordered(stream_id, events, attempt)
    {:noreply, state}
  end

  # coveralls-ignore-stop

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def broadcast_projected(stream_id, events) do
    event_types = events |> Enum.map(& &1.event_type) |> Enum.uniq()

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "projector:#{stream_id}",
      {:projected, stream_id, event_types}
    )
  end

  # --- Projection Logic ---

  @max_projection_retries 3
  @projection_base_backoff_ms 100
  @projection_max_backoff_ms 5_000

  defp do_project(stream_id, events) do
    do_project_ordered(stream_id, events, 0)
  end

  defp do_project_ordered(_stream_id, [], _attempt), do: :ok

  defp do_project_ordered(stream_id, [event | rest], attempt) do
    project_event(event)
    do_project_ordered(stream_id, rest, 0)
  rescue
    e in [
      Postgrex.Error,
      DBConnection.ConnectionError,
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      Ecto.InvalidChangesetError,
      Ecto.Query.CastError,
      Ecto.ChangeError
    ] ->
      handle_projection_error(stream_id, event, rest, attempt, e)
  end

  # coveralls-ignore-start - retry/failure paths require transient DB errors
  defp handle_projection_error(stream_id, event, rest, attempt, error) when attempt < @max_projection_retries do
    if retryable_projection_error?(error) do
      backoff_ms = retry_backoff_ms(attempt)

      Logger.warning(
        "Projector retrying: stream=#{stream_id} event=#{event.event_type} " <>
          "version=#{event.stream_version} attempt=#{attempt + 1}/#{@max_projection_retries} " <>
          "backoff=#{backoff_ms}ms"
      )

      :telemetry.execute(
        [:liteskill, :projector, :event_retrying],
        %{count: 1, backoff_ms: backoff_ms},
        %{
          stream_id: stream_id,
          event_type: event.event_type,
          stream_version: event.stream_version,
          attempt: attempt + 1
        }
      )

      # Schedule retry of the failed event AND all remaining events to preserve ordering
      Process.send_after(
        self(),
        {:retry_projection_batch, stream_id, [event | rest], attempt + 1},
        backoff_ms
      )
    else
      log_projection_failure(stream_id, event, attempt, error)
      # Still attempt remaining events — the failed event was non-retryable (constraint, cast, etc.)
      do_project_ordered(stream_id, rest, 0)
    end
  end

  defp handle_projection_error(stream_id, event, rest, attempt, error) do
    log_projection_failure(stream_id, event, attempt, error)
    # Exhausted retries for this event — skip it and continue with rest
    do_project_ordered(stream_id, rest, 0)
  end

  defp log_projection_failure(stream_id, event, attempt, error) do
    Logger.error(
      "Projector failed: stream=#{stream_id} event=#{event.event_type} " <>
        "version=#{event.stream_version} error=#{Exception.message(error)} " <>
        "attempts=#{attempt + 1}"
    )

    :telemetry.execute(
      [:liteskill, :projector, :event_failed],
      %{count: 1},
      %{
        stream_id: stream_id,
        event_type: event.event_type,
        stream_version: event.stream_version,
        error: Exception.message(error)
      }
    )
  end

  # Exponential backoff with jitter to avoid thundering herd on DB recovery.
  defp retry_backoff_ms(attempt) do
    base = min(@projection_base_backoff_ms * Integer.pow(2, attempt), @projection_max_backoff_ms)
    jitter = :rand.uniform(max(1, div(base, 2)))
    base + jitter
  end

  defp retryable_projection_error?(%DBConnection.ConnectionError{}), do: true
  defp retryable_projection_error?(%Postgrex.Error{}), do: true
  defp retryable_projection_error?(_), do: false

  # coveralls-ignore-stop

  defp project_event(%Event{event_type: "ConversationCreated", data: data, stream_id: stream_id}) do
    %Conversation{}
    |> Conversation.changeset(%{
      id: data["conversation_id"],
      stream_id: stream_id,
      user_id: data["user_id"],
      title: data["title"],
      model_id: data["model_id"],
      system_prompt: data["system_prompt"],
      llm_model_id: data["llm_model_id"],
      status: "active"
    })
    |> Repo.insert!(on_conflict: :nothing)
  end

  defp project_event(%Event{event_type: "UserMessageAdded", data: data, stream_id: stream_id, stream_version: version}) do
    with_conversation(stream_id, fn conversation ->
      Repo.transaction(fn ->
        message_count = increment_message_count(conversation.id)

        %Message{}
        |> Message.changeset(%{
          id: data["message_id"],
          conversation_id: conversation.id,
          role: "user",
          content: data["content"],
          status: "complete",
          position: message_count,
          stream_version: version,
          tool_config: data["tool_config"]
        })
        |> Repo.insert!(on_conflict: :nothing)

        Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
          set: [last_message_at: DateTime.truncate(DateTime.utc_now(), :second)]
        )
      end)
    end)
  end

  defp project_event(%Event{
         event_type: "AssistantStreamStarted",
         data: data,
         stream_id: stream_id,
         stream_version: version
       }) do
    with_conversation(stream_id, fn conversation ->
      Repo.transaction(fn ->
        message_count = increment_message_count(conversation.id)

        %Message{}
        |> Message.changeset(%{
          id: data["message_id"],
          conversation_id: conversation.id,
          role: "assistant",
          content: "",
          status: "streaming",
          model_id: data["model_id"],
          position: message_count,
          stream_version: version,
          rag_sources: data["rag_sources"]
        })
        |> Repo.insert!(on_conflict: :nothing)

        Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id), set: [status: "streaming"])
      end)
    end)
  end

  defp project_event(%Event{event_type: "AssistantChunkReceived", data: data}) do
    case Repo.get(Message, data["message_id"]) do
      nil ->
        Logger.warning("Projector: message not found for chunk, skipping")

      message ->
        %MessageChunk{}
        |> MessageChunk.changeset(%{
          message_id: message.id,
          chunk_index: data["chunk_index"],
          content_block_index: data["content_block_index"] || 0,
          delta_type: data["delta_type"] || "text_delta",
          delta_text: data["delta_text"]
        })
        |> Repo.insert!()
    end
  end

  @uuid_re ~r/\[uuid:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/

  defp project_event(%Event{event_type: "AssistantStreamCompleted", data: data, stream_id: stream_id}) do
    case Repo.get(Message, data["message_id"]) do
      nil ->
        Logger.warning("Projector: message not found for stream completion, skipping")

      message ->
        input_tokens = data["input_tokens"]
        output_tokens = data["output_tokens"]

        total_tokens =
          if input_tokens && output_tokens, do: input_tokens + output_tokens

        filtered_sources = filter_cited_sources(message.rag_sources, data["full_content"])

        Repo.transaction(fn ->
          message
          |> Message.changeset(%{
            content: data["full_content"],
            status: "complete",
            stop_reason: data["stop_reason"],
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            total_tokens: total_tokens,
            latency_ms: data["latency_ms"],
            rag_sources: filtered_sources
          })
          |> Repo.update!()

          with_conversation(stream_id, fn conversation ->
            conversation
            |> Conversation.changeset(%{
              status: "active",
              last_message_at: DateTime.truncate(DateTime.utc_now(), :second)
            })
            |> Repo.update!()
          end)
        end)
    end
  end

  defp project_event(%Event{event_type: "AssistantStreamFailed", data: data, stream_id: stream_id}) do
    with_conversation(stream_id, fn conversation ->
      Repo.transaction(fn ->
        conversation
        |> Conversation.changeset(%{status: "active"})
        |> Repo.update!()

        # Mark the streaming message as failed
        if data["message_id"] do
          case Repo.get(Message, data["message_id"]) do
            %Message{status: "streaming"} = msg ->
              msg
              |> Message.changeset(%{status: "failed", stop_reason: "error"})
              |> Repo.update!()

            _ ->
              :ok
          end
        end
      end)
    end)
  end

  defp project_event(%Event{event_type: "ToolCallStarted", data: data}) do
    %ToolCall{}
    |> ToolCall.changeset(%{
      message_id: data["message_id"],
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: "started"
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:tool_use_id])
  end

  defp project_event(%Event{event_type: "ToolCallCompleted", data: data}) do
    case Repo.one(from tc in ToolCall, where: tc.tool_use_id == ^data["tool_use_id"]) do
      nil ->
        Logger.warning("ToolCall not found for tool_use_id=#{data["tool_use_id"]}, skipping")

      tool_call ->
        tool_call
        |> ToolCall.changeset(%{
          input: data["input"],
          output: data["output"],
          status: "completed",
          duration_ms: data["duration_ms"]
        })
        |> Repo.update!()
    end
  end

  defp project_event(%Event{event_type: "ConversationForked", data: data, stream_id: stream_id}) do
    parent =
      Repo.one(from c in Conversation, where: c.stream_id == ^data["parent_stream_id"])

    if is_nil(parent) do
      Logger.warning(
        "Projector: parent conversation not found for stream=#{data["parent_stream_id"]} " <>
          "while projecting ConversationForked on stream=#{stream_id} — fork tree may be incomplete"
      )
    end

    with_conversation(stream_id, fn conversation ->
      conversation
      |> Conversation.changeset(%{
        parent_conversation_id: parent && parent.id,
        fork_at_version: data["fork_at_version"]
      })
      |> Repo.update!()
    end)
  end

  defp project_event(%Event{event_type: "ConversationTitleUpdated", data: data, stream_id: stream_id}) do
    with_conversation(stream_id, fn conversation ->
      conversation
      |> Conversation.changeset(%{title: data["title"]})
      |> Repo.update!()
    end)
  end

  defp project_event(%Event{event_type: "ConversationArchived", stream_id: stream_id}) do
    with_conversation(stream_id, fn conversation ->
      conversation
      |> Conversation.changeset(%{status: "archived"})
      |> Repo.update!()
    end)
  end

  defp project_event(%Event{event_type: "ConversationTruncated", data: data, stream_id: stream_id}) do
    with_conversation(stream_id, fn conversation ->
      case Repo.get(Message, data["message_id"]) do
        nil ->
          Logger.warning("Projector: truncation target message #{data["message_id"]} not found, skipping")

        target_message ->
          {:ok, _} =
            Repo.transaction(fn ->
              # Delete target message and everything after it (cascade deletes chunks + tool_calls)
              {deleted, _} =
                Repo.delete_all(
                  from(m in Message,
                    where: m.conversation_id == ^conversation.id and m.position >= ^target_message.position
                  )
                )

              Logger.info(
                # coveralls-ignore-next-line
                "Projector: truncated #{deleted} message(s) at position >= #{target_message.position}"
              )

              conversation
              |> Conversation.changeset(%{
                message_count: target_message.position - 1,
                status: "active"
              })
              |> Repo.update!()
            end)
      end
    end)
  end

  defp project_event(_event), do: :ok

  defp do_rebuild do
    Repo.transaction(
      fn ->
        Repo.delete_all(MessageChunk)
        Repo.delete_all(ToolCall)
        Repo.delete_all(Message)
        Repo.delete_all(Conversation)

        Event
        |> order_by([e], asc: e.inserted_at, asc: e.stream_version)
        |> Repo.stream(max_rows: 500)
        # coveralls-ignore-start — rebuild rescue requires transient DB errors
        |> Enum.each(fn event ->
          try do
            project_event(event)
          rescue
            e ->
              Logger.error(
                "Projector rebuild failed: event=#{event.event_type} " <>
                  "stream=#{event.stream_id} version=#{event.stream_version} " <>
                  "error=#{Exception.message(e)}"
              )
          end
        end)

        # coveralls-ignore-stop
      end,
      timeout: :infinity
    )
  end

  defp with_conversation(stream_id, fun) do
    case Repo.one(from c in Conversation, where: c.stream_id == ^stream_id) do
      nil ->
        Logger.warning("Projector: conversation not found for stream=#{stream_id}, skipping event")

        :telemetry.execute(
          [:liteskill, :projector, :conversation_not_found],
          %{count: 1},
          %{stream_id: stream_id}
        )

      conversation ->
        fun.(conversation)
    end
  end

  # Atomically increment message_count and return the new value.
  # Uses a single UPDATE ... RETURNING to avoid read-modify-write races.
  defp increment_message_count(conversation_id) do
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id,
        select: %{message_count: c.message_count}
      )

    {1, [%{message_count: new_count}]} =
      Repo.update_all(query, inc: [message_count: 1])

    new_count
  end

  defp filter_cited_sources(nil, _content), do: nil
  defp filter_cited_sources([], _content), do: []
  defp filter_cited_sources(_sources, nil), do: nil

  defp filter_cited_sources(sources, content) do
    cited_ids =
      @uuid_re
      |> Regex.scan(content)
      |> MapSet.new(fn [_full, uuid] -> uuid end)

    case Enum.filter(sources, &MapSet.member?(cited_ids, &1["document_id"])) do
      [] -> nil
      filtered -> filtered
    end
  end
end
