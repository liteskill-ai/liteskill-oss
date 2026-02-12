defmodule Liteskill.DataSources.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "data_sources" do
    field :name, :string
    field :source_type, :string
    field :description, :string
    field :metadata, Liteskill.Crypto.EncryptedMap, default: %{}

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :source_type, :description, :metadata, :user_id])
    |> validate_required([:name, :source_type, :user_id])
    |> foreign_key_constraint(:user_id)
  end
end
