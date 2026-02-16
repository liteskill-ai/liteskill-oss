defmodule Liteskill.Rag.Document do
  @moduledoc """
  Schema for RAG documents within a source.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_documents" do
    field :title, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :chunk_count, :integer, default: 0
    field :status, :string, default: "pending"
    field :error_message, :string
    field :content_hash, :string

    belongs_to :source, Liteskill.Rag.Source
    belongs_to :user, Liteskill.Accounts.User
    has_many :chunks, Liteskill.Rag.Chunk

    timestamps(type: :utc_datetime)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :title,
      :content,
      :metadata,
      :chunk_count,
      :status,
      :error_message,
      :content_hash,
      :source_id,
      :user_id
    ])
    |> validate_required([:title, :source_id, :user_id])
    |> validate_inclusion(:status, ["pending", "embedded", "error"])
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:user_id)
  end
end
