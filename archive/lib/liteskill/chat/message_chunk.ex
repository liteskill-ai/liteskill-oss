defmodule Liteskill.Chat.MessageChunk do
  @moduledoc """
  Projection schema for streaming chunks of an assistant message.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_chunks" do
    field :chunk_index, :integer
    field :content_block_index, :integer, default: 0
    field :delta_type, :string, default: "text_delta"
    field :delta_text, :string
    field :inserted_at, :utc_datetime

    belongs_to :message, Liteskill.Chat.Message
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:message_id, :chunk_index, :content_block_index, :delta_type, :delta_text])
    |> validate_required([:message_id, :chunk_index])
    |> foreign_key_constraint(:message_id)
  end
end
