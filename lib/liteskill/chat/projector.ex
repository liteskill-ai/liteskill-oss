defmodule Liteskill.Chat.Projector do
  @moduledoc """
  GenServer that subscribes to PubSub event broadcasts and updates
  projection tables (conversations, messages, chunks, tool_calls).

  Also supports `rebuild_projections/0` to replay all events from scratch.
  """

  use GenServer

  require Logger

  alias Liteskill.Chat.{Conversation, Message, MessageChunk, ToolCall}
  alias Liteskill.EventStore.Event
  alias Liteskill.Repo

  import Ecto.Query

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

  # --- Projection Logic ---

  defp do_project(_stream_id, events) do
    Enum.each(events, fn event ->
      try do
        project_event(event)
      rescue
        # coveralls-ignore-start
        e ->
          Logger.error("Projector failed on #{event.event_type}: #{Exception.message(e)}")
          # coveralls-ignore-stop
      end
    end)
  end

  defp project_event(%Event{event_type: "ConversationCreated", data: data, stream_id: stream_id}) do
    %Conversation{}
    |> Conversation.changeset(%{
      id: data["conversation_id"],
      stream_id: stream_id,
      user_id: data["user_id"],
      title: data["title"],
      model_id: data["model_id"],
      system_prompt: data["system_prompt"],
      status: "active"
    })
    |> Repo.insert!(on_conflict: :nothing)
  end

  defp project_event(%Event{
         event_type: "UserMessageAdded",
         data: data,
         stream_id: stream_id,
         stream_version: version
       }) do
    with_conversation(stream_id, fn conversation ->
      Repo.transaction(fn ->
        message_count = conversation.message_count + 1

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

        conversation
        |> Conversation.changeset(%{
          message_count: message_count,
          last_message_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
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
        message_count = conversation.message_count + 1

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

        conversation
        |> Conversation.changeset(%{
          message_count: message_count,
          status: "streaming"
        })
        |> Repo.update!()
      end)
    end)
  end

  defp project_event(%Event{event_type: "AssistantChunkReceived", data: data}) do
    case Repo.get(Message, data["message_id"]) do
      # coveralls-ignore-start
      nil ->
        Logger.warning("Projector: message not found for chunk, skipping")

      # coveralls-ignore-stop
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

  defp project_event(%Event{
         event_type: "AssistantStreamCompleted",
         data: data,
         stream_id: stream_id
       }) do
    case Repo.get(Message, data["message_id"]) do
      # coveralls-ignore-start
      nil ->
        Logger.warning("Projector: message not found for stream completion, skipping")

      # coveralls-ignore-stop
      message ->
        input_tokens = data["input_tokens"]
        output_tokens = data["output_tokens"]

        total_tokens =
          if input_tokens && output_tokens, do: input_tokens + output_tokens, else: nil

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
              last_message_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.update!()
          end)
        end)
    end
  end

  defp project_event(%Event{
         event_type: "AssistantStreamFailed",
         data: data,
         stream_id: stream_id
       }) do
    with_conversation(stream_id, fn conversation ->
      conversation
      |> Conversation.changeset(%{status: "active"})
      |> Repo.update!()
    end)

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
    |> Repo.insert!()
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

    with_conversation(stream_id, fn conversation ->
      conversation
      |> Conversation.changeset(%{
        parent_conversation_id: parent && parent.id,
        fork_at_version: data["fork_at_version"]
      })
      |> Repo.update!()
    end)
  end

  defp project_event(%Event{
         event_type: "ConversationTitleUpdated",
         data: data,
         stream_id: stream_id
       }) do
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

  defp project_event(_event), do: :ok

  defp do_rebuild do
    Repo.transaction(fn ->
      Repo.delete_all(MessageChunk)
      Repo.delete_all(ToolCall)
      Repo.delete_all(Message)
      Repo.delete_all(Conversation)

      Event
      |> order_by([e], asc: e.inserted_at, asc: e.stream_version)
      |> Repo.all()
      |> Enum.each(&project_event/1)
    end)
  end

  defp with_conversation(stream_id, fun) do
    case Repo.one(from c in Conversation, where: c.stream_id == ^stream_id) do
      nil ->
        Logger.warning(
          "Projector: conversation not found for stream #{stream_id}, skipping event"
        )

      conversation ->
        fun.(conversation)
    end
  end

  defp filter_cited_sources(nil, _content), do: nil
  defp filter_cited_sources([], _content), do: []
  defp filter_cited_sources(_sources, nil), do: nil

  defp filter_cited_sources(sources, content) do
    cited_ids =
      @uuid_re
      |> Regex.scan(content)
      |> Enum.map(fn [_full, uuid] -> uuid end)
      |> MapSet.new()

    case Enum.filter(sources, &MapSet.member?(cited_ids, &1["document_id"])) do
      [] -> nil
      filtered -> filtered
    end
  end
end
