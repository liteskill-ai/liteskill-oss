defmodule Liteskill.Chat.ConversationAggregate do
  @moduledoc """
  Event-sourced aggregate for conversations.

  State machine: :created -> :active <-> :streaming -> :archived
  """

  @behaviour Liteskill.Aggregate

  alias Liteskill.Chat.Events

  require Logger

  defstruct [
    :conversation_id,
    :user_id,
    :title,
    :model_id,
    :system_prompt,
    :llm_model_id,
    :parent_stream_id,
    :fork_at_version,
    status: :created,
    messages: [],
    current_stream: nil
  ]

  @valid_statuses ~w(created active streaming archived)a

  def valid_statuses, do: @valid_statuses

  @impl true
  def init, do: %__MODULE__{}

  # --- Command Handlers ---

  @impl true
  def handle_command(%{status: :created}, {:create_conversation, params}) do
    event =
      Events.serialize(%Events.ConversationCreated{
        conversation_id: params.conversation_id,
        user_id: params.user_id,
        title: params.title,
        model_id: params.model_id,
        system_prompt: params[:system_prompt],
        llm_model_id: params[:llm_model_id]
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:create_conversation, _}) when status != :created do
    {:error, :already_created}
  end

  def handle_command(%{status: :created}, {:add_user_message, _}) do
    {:error, :not_active}
  end

  def handle_command(%{status: :archived}, {:add_user_message, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: :streaming}, {:add_user_message, _}) do
    {:error, :currently_streaming}
  end

  def handle_command(%{status: :active}, {:add_user_message, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.UserMessageAdded{
        message_id: params[:message_id] || Ecto.UUID.generate(),
        content: params.content,
        timestamp: now,
        tool_config: params[:tool_config]
      })

    {:ok, [event]}
  end

  def handle_command(%{status: :streaming}, {:start_assistant_stream, _}) do
    {:error, :already_streaming}
  end

  def handle_command(%{status: :archived}, {:start_assistant_stream, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: :active}, {:start_assistant_stream, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.AssistantStreamStarted{
        message_id: params[:message_id] || Ecto.UUID.generate(),
        model_id: params.model_id,
        request_id: params[:request_id] || Ecto.UUID.generate(),
        timestamp: now,
        rag_sources: params[:rag_sources]
      })

    {:ok, [event]}
  end

  def handle_command(%{status: :streaming}, {:receive_chunk, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.AssistantChunkReceived{
        message_id: params.message_id,
        chunk_index: params.chunk_index,
        content_block_index: params[:content_block_index] || 0,
        delta_type: params[:delta_type] || "text_delta",
        delta_text: params.delta_text,
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:receive_chunk, _}) when status != :streaming do
    {:error, :not_streaming}
  end

  def handle_command(%{status: :streaming}, {:complete_stream, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.AssistantStreamCompleted{
        message_id: params.message_id,
        full_content: params.full_content,
        stop_reason: params[:stop_reason] || "end_turn",
        input_tokens: params[:input_tokens],
        output_tokens: params[:output_tokens],
        latency_ms: params[:latency_ms],
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:complete_stream, _}) when status != :streaming do
    {:error, :not_streaming}
  end

  def handle_command(%{status: :streaming}, {:fail_stream, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.AssistantStreamFailed{
        message_id: params.message_id,
        error_type: params.error_type,
        error_message: params.error_message,
        retry_count: params[:retry_count] || 0,
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:fail_stream, _}) when status != :streaming do
    {:error, :not_streaming}
  end

  def handle_command(%{status: :streaming}, {:start_tool_call, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.ToolCallStarted{
        message_id: params.message_id,
        tool_use_id: params.tool_use_id,
        tool_name: params.tool_name,
        input: params[:input],
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:start_tool_call, _}) when status != :streaming do
    {:error, :not_streaming}
  end

  def handle_command(%{status: status}, {:complete_tool_call, params}) when status in [:streaming, :active] do
    now = iso_now()

    event =
      Events.serialize(%Events.ToolCallCompleted{
        message_id: params.message_id,
        tool_use_id: params.tool_use_id,
        tool_name: params.tool_name,
        input: params[:input],
        output: params[:output],
        duration_ms: params[:duration_ms],
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: _status}, {:complete_tool_call, _}) do
    {:error, :not_streaming}
  end

  def handle_command(%{status: :archived}, {:update_title, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: :created}, {:update_title, _}), do: {:error, :not_active}

  def handle_command(%{status: _status}, {:update_title, params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.ConversationTitleUpdated{
        title: params.title,
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: :archived}, {:archive, _}) do
    {:error, :already_archived}
  end

  def handle_command(%{status: :created}, {:archive, _}), do: {:error, :not_active}

  def handle_command(%{status: _status}, {:archive, _params}) do
    now = iso_now()

    event =
      Events.serialize(%Events.ConversationArchived{
        timestamp: now
      })

    {:ok, [event]}
  end

  def handle_command(%{status: :created}, {:truncate_conversation, _}) do
    {:error, :no_messages}
  end

  def handle_command(%{status: :archived}, {:truncate_conversation, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: status, messages: messages}, {:truncate_conversation, params})
      when status in [:active, :streaming] do
    message_id = params.message_id

    if Enum.any?(messages, &(&1.id == message_id)) do
      now = iso_now()

      event =
        Events.serialize(%Events.ConversationTruncated{
          message_id: message_id,
          timestamp: now
        })

      {:ok, [event]}
    else
      {:error, :message_not_found}
    end
  end

  def handle_command(_state, {command_type, _params}) do
    {:error, {:unknown_command, command_type}}
  end

  defp iso_now, do: DateTime.to_iso8601(DateTime.utc_now())

  # --- Event Appliers ---

  @impl true
  def apply_event(state, %{event_type: "ConversationCreated", data: data}) do
    %{
      state
      | conversation_id: data["conversation_id"],
        user_id: data["user_id"],
        title: data["title"],
        model_id: data["model_id"],
        system_prompt: data["system_prompt"],
        llm_model_id: data["llm_model_id"],
        status: :active
    }
  end

  def apply_event(state, %{event_type: "UserMessageAdded", data: data}) do
    message = %{
      id: data["message_id"],
      role: "user",
      content: data["content"],
      timestamp: data["timestamp"],
      tool_config: data["tool_config"]
    }

    %{state | messages: [message | state.messages]}
  end

  def apply_event(state, %{event_type: "AssistantStreamStarted", data: data}) do
    %{
      state
      | status: :streaming,
        current_stream: %{
          message_id: data["message_id"],
          model_id: data["model_id"],
          chunks: [],
          tool_calls: []
        }
    }
  end

  def apply_event(%{current_stream: nil} = state, %{event_type: "AssistantChunkReceived"}) do
    Logger.warning("AssistantChunkReceived received with no active stream — event stream may be corrupted")

    state
  end

  def apply_event(state, %{event_type: "AssistantChunkReceived"}) do
    # Chunks are projected to the DB by the Projector — no need to accumulate
    # them in aggregate state. Skipping avoids O(n^2) replay cost during streaming.
    state
  end

  def apply_event(state, %{event_type: "AssistantStreamCompleted", data: data}) do
    message = %{
      id: data["message_id"],
      role: "assistant",
      content: data["full_content"],
      stop_reason: data["stop_reason"],
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      latency_ms: data["latency_ms"],
      timestamp: data["timestamp"]
    }

    %{
      state
      | status: :active,
        messages: [message | state.messages],
        current_stream: nil
    }
  end

  def apply_event(state, %{event_type: "AssistantStreamFailed", data: _data}) do
    %{state | status: :active, current_stream: nil}
  end

  def apply_event(%{current_stream: nil} = state, %{event_type: "ToolCallStarted"}) do
    Logger.warning("ToolCallStarted received with no active stream — event stream may be corrupted")

    state
  end

  def apply_event(state, %{event_type: "ToolCallStarted", data: data}) do
    tool_call = %{
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: :started
    }

    current_stream = %{
      state.current_stream
      | tool_calls: [tool_call | state.current_stream.tool_calls]
    }

    %{state | current_stream: current_stream}
  end

  def apply_event(state, %{event_type: "ToolCallCompleted", data: data}) do
    case state.current_stream do
      nil ->
        # Tool call completed in :active state (manual confirm flow)
        state

      current_stream ->
        tool_calls =
          Enum.map(current_stream.tool_calls, fn tc ->
            if tc.tool_use_id == data["tool_use_id"] do
              %{tc | status: :completed}
            else
              tc
            end
          end)

        %{state | current_stream: %{current_stream | tool_calls: tool_calls}}
    end
  end

  def apply_event(state, %{event_type: "ConversationForked", data: data}) do
    %{
      state
      | parent_stream_id: data["parent_stream_id"],
        fork_at_version: data["fork_at_version"]
    }
  end

  def apply_event(state, %{event_type: "ConversationTitleUpdated", data: data}) do
    %{state | title: data["title"]}
  end

  def apply_event(state, %{event_type: "ConversationArchived", data: _data}) do
    %{state | status: :archived}
  end

  def apply_event(state, %{event_type: "ConversationTruncated", data: data}) do
    message_id = data["message_id"]
    # Messages are newest-first. Drop the target and everything newer than it.
    kept =
      state.messages
      |> Enum.drop_while(&(&1.id != message_id))
      |> Enum.drop(1)

    %{state | messages: kept, status: :active, current_stream: nil}
  end
end
