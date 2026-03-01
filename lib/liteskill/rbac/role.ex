defmodule Liteskill.Rbac.Role do
  use Ecto.Schema
  import Ecto.Changeset

  alias Liteskill.Rbac.Permissions

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    field :name, :string
    field :description, :string
    field :system, :boolean, default: false
    field :permissions, {:array, :string}, default: []

    has_many :user_roles, Liteskill.Rbac.UserRole
    has_many :group_roles, Liteskill.Rbac.GroupRole
    has_many :agent_roles, Liteskill.Rbac.AgentRole

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :permissions])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> validate_permissions()
  end

  def system_changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :system, :permissions])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> validate_permissions()
  end

  defp validate_permissions(changeset) do
    validate_change(changeset, :permissions, fn :permissions, perms ->
      invalid = Enum.reject(perms, &Permissions.valid?/1)

      if invalid == [] do
        []
      else
        [{:permissions, "contains invalid permissions: #{Enum.join(invalid, ", ")}"}]
      end
    end)
  end
end
