defmodule Liteskill.McpServers.UserToolSelection do
  @moduledoc """
  Schema for persisting per-user tool server selections.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_tool_selections" do
    field :server_id, :string

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(selection, attrs) do
    selection
    |> cast(attrs, [:server_id, :user_id])
    |> validate_required([:server_id, :user_id])
    |> unique_constraint([:user_id, :server_id])
    |> foreign_key_constraint(:user_id)
  end
end
