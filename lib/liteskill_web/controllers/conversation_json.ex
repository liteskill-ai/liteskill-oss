defmodule LiteskillWeb.ConversationJSON do
  @moduledoc """
  JSON view helpers for conversation API responses.
  """

  alias Liteskill.Chat.Conversation
  alias Liteskill.Chat.Message

  def index(%{conversations: conversations}) do
    %{data: Enum.map(conversations, &conversation_summary/1)}
  end

  def show(%{conversation: conversation}) do
    %{data: conversation_detail(conversation)}
  end

  def create(%{conversation: conversation}) do
    %{data: conversation_summary(conversation)}
  end

  def message(%{message: message}) do
    %{data: message_data(message)}
  end

  def fork(%{conversation: conversation}) do
    %{data: conversation_summary(conversation)}
  end

  defp conversation_summary(%Conversation{} = conv) do
    %{
      id: conv.id,
      title: conv.title,
      model_id: conv.model_id,
      status: conv.status,
      message_count: conv.message_count,
      last_message_at: conv.last_message_at,
      parent_conversation_id: conv.parent_conversation_id,
      inserted_at: conv.inserted_at,
      updated_at: conv.updated_at
    }
  end

  defp conversation_detail(%Conversation{} = conv) do
    %{
      id: conv.id,
      title: conv.title,
      model_id: conv.model_id,
      system_prompt: conv.system_prompt,
      status: conv.status,
      message_count: conv.message_count,
      last_message_at: conv.last_message_at,
      parent_conversation_id: conv.parent_conversation_id,
      messages: Enum.map(conv.messages || [], &message_data/1),
      inserted_at: conv.inserted_at,
      updated_at: conv.updated_at
    }
  end

  defp message_data(%Message{} = msg) do
    %{
      id: msg.id,
      role: msg.role,
      content: msg.content,
      status: msg.status,
      model_id: msg.model_id,
      stop_reason: msg.stop_reason,
      input_tokens: msg.input_tokens,
      output_tokens: msg.output_tokens,
      total_tokens: msg.total_tokens,
      latency_ms: msg.latency_ms,
      position: msg.position,
      inserted_at: msg.inserted_at
    }
  end
end
