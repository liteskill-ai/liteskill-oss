defmodule Liteskill.DataSources.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "data_sources" do
    field :name, :string
    field :source_type, :string
    field :description, :string
    field :metadata, Liteskill.Crypto.EncryptedMap, default: %{}
    field :sync_cursor, :map, default: %{}
    field :sync_status, :string, default: "idle"
    field :last_synced_at, :utc_datetime
    field :last_sync_error, :string
    field :sync_document_count, :integer, default: 0

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :source_type, :description, :metadata, :user_id])
    |> validate_required([:name, :source_type, :user_id])
    |> foreign_key_constraint(:user_id)
  end

  def sync_changeset(source, attrs) do
    source
    |> cast(attrs, [
      :sync_cursor,
      :sync_status,
      :last_synced_at,
      :last_sync_error,
      :sync_document_count
    ])
    |> validate_inclusion(:sync_status, ["idle", "syncing", "error", "complete"])
  end
end
