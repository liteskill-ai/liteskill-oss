defmodule Liteskill.Groups.GroupMembership do
  @moduledoc """
  Schema for group membership entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_memberships" do
    field :role, :string, default: "member"

    belongs_to :group, Liteskill.Groups.Group
    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:group_id, :user_id, :role])
    |> validate_required([:group_id, :user_id, :role])
    |> validate_inclusion(:role, ["owner", "member"])
    |> unique_constraint([:group_id, :user_id])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:user_id)
  end
end
