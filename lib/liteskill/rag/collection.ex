defmodule Liteskill.Rag.Collection do
  @moduledoc """
  Schema for RAG document collections.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_collections" do
    field :name, :string
    field :description, :string
    field :embedding_dimensions, :integer, default: 1024

    belongs_to :user, Liteskill.Accounts.User
    has_many :sources, Liteskill.Rag.Source

    timestamps(type: :utc_datetime)
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :description, :embedding_dimensions, :user_id])
    |> validate_required([:name, :user_id])
    |> validate_inclusion(:embedding_dimensions, [256, 384, 512, 768, 1024, 1536])
    |> foreign_key_constraint(:user_id)
  end
end
