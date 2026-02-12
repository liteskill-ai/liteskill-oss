defmodule Liteskill.Chat.ConversationAggregate do
  @moduledoc """
  Event-sourced aggregate for conversations.

  State machine: :created -> :active <-> :streaming -> :archived
  """

  @behaviour Liteskill.Aggregate

  alias Liteskill.Chat.Events

  defstruct [
    :conversation_id,
    :user_id,
    :title,
    :model_id,
    :system_prompt,
    :parent_stream_id,
    :fork_at_version,
    status: :created,
    messages: [],
    current_stream: nil
  ]

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
        system_prompt: params[:system_prompt]
      })

    {:ok, [event]}
  end

  def handle_command(%{status: status}, {:create_conversation, _})
      when status != :created do
    {:error, :already_created}
  end

  def handle_command(%{status: :archived}, {:add_user_message, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: :streaming}, {:add_user_message, _}) do
    {:error, :currently_streaming}
  end

  def handle_command(%{status: :active}, {:add_user_message, params}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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

  def handle_command(%{status: :streaming}, {:complete_tool_call, params}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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

  def handle_command(%{status: status}, {:complete_tool_call, _})
      when status != :streaming do
    {:error, :not_streaming}
  end

  def handle_command(%{status: :archived}, {:update_title, _}) do
    {:error, :conversation_archived}
  end

  def handle_command(%{status: _status}, {:update_title, params}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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

  def handle_command(%{status: _status}, {:archive, _params}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    event =
      Events.serialize(%Events.ConversationArchived{
        timestamp: now
      })

    {:ok, [event]}
  end

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

  def apply_event(state, %{event_type: "AssistantChunkReceived", data: data}) do
    chunk = %{
      chunk_index: data["chunk_index"],
      delta_text: data["delta_text"],
      delta_type: data["delta_type"]
    }

    current_stream = %{state.current_stream | chunks: [chunk | state.current_stream.chunks]}
    %{state | current_stream: current_stream}
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
              # coveralls-ignore-next-line
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
end
