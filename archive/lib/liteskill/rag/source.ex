defmodule Liteskill.Rag.Source do
  @moduledoc """
  Schema for RAG sources within a collection.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_sources" do
    field :name, :string
    field :source_type, :string, default: "manual"
    field :metadata, :map, default: %{}

    belongs_to :collection, Liteskill.Rag.Collection
    belongs_to :user, Liteskill.Accounts.User
    has_many :documents, Liteskill.Rag.Document

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :source_type, :metadata, :collection_id, :user_id])
    |> validate_required([:name, :collection_id, :user_id])
    |> validate_inclusion(:source_type, ["manual", "upload", "web", "api"])
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:user_id)
  end
end
