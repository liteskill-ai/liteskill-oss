defmodule Liteskill.Accounts.UserSession do
  @moduledoc """
  Schema for server-side session tracking. Created programmatically (no changeset).
  The `id` (PK) doubles as the session token stored in the cookie.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_sessions" do
    belongs_to :user, Liteskill.Accounts.User
    field :ip_address, :string
    field :user_agent, :string
    field :last_active_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
