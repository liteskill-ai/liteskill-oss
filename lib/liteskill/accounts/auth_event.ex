defmodule Liteskill.Accounts.AuthEvent do
  @moduledoc """
  Append-only audit log for authentication events. Created programmatically (no changeset).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "auth_events" do
    belongs_to :user, Liteskill.Accounts.User
    field :event_type, :string
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
