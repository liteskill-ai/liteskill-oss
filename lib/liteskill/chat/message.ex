defmodule Liteskill.Chat.Message do
  @moduledoc """
  Projection schema for messages within a conversation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :role, :string
    field :content, :string
    field :status, :string, default: "complete"
    field :model_id, :string
    field :stop_reason, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :latency_ms, :integer
    field :stream_version, :integer
    field :position, :integer
    field :rag_sources, {:array, :map}
    field :tool_config, :map

    belongs_to :conversation, Liteskill.Chat.Conversation
    has_many :chunks, Liteskill.Chat.MessageChunk
    has_many :tool_calls, Liteskill.Chat.ToolCall

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :id,
      :conversation_id,
      :role,
      :content,
      :status,
      :model_id,
      :stop_reason,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :latency_ms,
      :stream_version,
      :position,
      :rag_sources,
      :tool_config
    ])
    |> validate_required([:conversation_id, :role, :position])
    |> foreign_key_constraint(:conversation_id)
  end
end
