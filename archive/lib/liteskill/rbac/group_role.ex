defmodule Liteskill.Rbac.GroupRole do
  @moduledoc "Join schema associating a group with a role."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_roles" do
    belongs_to :group, Liteskill.Groups.Group
    belongs_to :role, Liteskill.Rbac.Role

    timestamps(type: :utc_datetime)
  end

  def changeset(group_role, attrs) do
    group_role
    |> cast(attrs, [:group_id, :role_id])
    |> validate_required([:group_id, :role_id])
    |> unique_constraint([:group_id, :role_id])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:role_id)
  end
end
