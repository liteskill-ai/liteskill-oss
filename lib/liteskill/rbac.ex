defmodule Liteskill.Rbac do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Accounts, Liteskill.Groups],
    exports: [Permissions, Role, UserRole, GroupRole]

  @moduledoc """
  Role-based access control context.

  Controls system-wide actions (create conversations, manage MCP servers, admin functions).
  Orthogonal to EntityAcl which controls per-resource access.
  """

  alias Liteskill.Rbac.{GroupRole, Permissions, Role, UserRole}
  alias Liteskill.Repo

  import Ecto.Query

  @instance_admin_name "Instance Admin"
  @default_role_name "Default"
  @root_admin_email Liteskill.Accounts.User.admin_email()

  # --- Boot-time seeding ---

  def ensure_system_roles do
    upsert_system_role(@instance_admin_name, "Full system access", ["*"])

    upsert_system_role(
      @default_role_name,
      "Baseline permissions for all users",
      Permissions.default_permissions()
    )

    migrate_admin_users()
  end

  defp upsert_system_role(name, description, permissions) do
    case Repo.one(from r in Role, where: r.name == ^name) do
      nil ->
        %Role{}
        |> Role.system_changeset(%{
          name: name,
          description: description,
          system: true,
          permissions: permissions
        })
        |> Repo.insert!()

      role ->
        role
        |> Role.system_changeset(%{description: description, permissions: permissions})
        |> Repo.update!()
    end
  end

  defp migrate_admin_users do
    admin_role = Repo.one!(from r in Role, where: r.name == ^@instance_admin_name)

    admin_user_ids =
      from(u in Liteskill.Accounts.User, where: u.role == "admin", select: u.id)
      |> Repo.all()

    for user_id <- admin_user_ids do
      %UserRole{}
      |> UserRole.changeset(%{user_id: user_id, role_id: admin_role.id})
      |> Repo.insert(on_conflict: :nothing)
    end
  end

  # --- Permission checking ---

  def has_permission?(user_id, permission) do
    permission in list_permissions(user_id)
  end

  def list_permissions(user_id) do
    direct = direct_role_permissions(user_id)
    group = group_role_permissions(user_id)
    default = default_role_permissions()

    all_perms = MapSet.union(MapSet.union(direct, group), default)

    if MapSet.member?(all_perms, "*") do
      MapSet.new(["*" | Permissions.all_permissions()])
    else
      all_perms
    end
  end

  def authorize(nil, _permission), do: {:error, :forbidden}

  def authorize(user_id, permission) do
    if has_permission?(user_id, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  def has_any_admin_permission?(user_id) do
    perms = list_permissions(user_id)

    MapSet.member?(perms, "*") or
      Enum.any?(perms, fn p ->
        String.starts_with?(p, "admin:") or
          p in ["groups:manage_all", "llm_providers:manage", "llm_models:manage"]
      end)
  end

  defp direct_role_permissions(user_id) do
    from(r in Role,
      join: ur in UserRole,
      on: ur.role_id == r.id,
      where: ur.user_id == ^user_id,
      select: r.permissions
    )
    |> Repo.all()
    |> List.flatten()
    |> MapSet.new()
  end

  defp group_role_permissions(user_id) do
    from(r in Role,
      join: gr in GroupRole,
      on: gr.role_id == r.id,
      join: gm in Liteskill.Groups.GroupMembership,
      on: gm.group_id == gr.group_id,
      where: gm.user_id == ^user_id,
      select: r.permissions
    )
    |> Repo.all()
    |> List.flatten()
    |> MapSet.new()
  end

  defp default_role_permissions do
    case Repo.one(from r in Role, where: r.name == ^@default_role_name, select: r.permissions) do
      nil -> MapSet.new(Permissions.default_permissions())
      perms -> MapSet.new(perms)
    end
  end

  # --- Role CRUD ---

  def list_roles do
    Role
    |> order_by([r], desc: r.system, asc: r.name)
    |> Repo.all()
  end

  def get_role(id) do
    case Repo.get(Role, id) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  def get_role_by_name!(name) do
    Repo.one!(from r in Role, where: r.name == ^name)
  end

  def create_role(attrs) do
    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  def update_role(%Role{system: true} = role, attrs) do
    role
    |> Role.system_changeset(Map.drop(attrs, [:name, "name"]))
    |> Repo.update()
  end

  def update_role(role, attrs) do
    role
    |> Role.changeset(attrs)
    |> Repo.update()
  end

  def delete_role(%Role{system: true}), do: {:error, :cannot_delete_system_role}

  def delete_role(role) do
    Repo.delete(role)
  end

  # --- User role assignments ---

  def assign_role_to_user(user_id, role_id) do
    %UserRole{}
    |> UserRole.changeset(%{user_id: user_id, role_id: role_id})
    |> Repo.insert()
  end

  def remove_role_from_user(user_id, role_id) do
    admin_role = Repo.one(from r in Role, where: r.name == ^@instance_admin_name)

    if admin_role && role_id == admin_role.id && root_admin?(user_id) do
      {:error, :cannot_remove_root_admin}
    else
      case Repo.one(from ur in UserRole, where: ur.user_id == ^user_id and ur.role_id == ^role_id) do
        nil -> {:error, :not_found}
        user_role -> Repo.delete(user_role)
      end
    end
  end

  def list_user_roles(user_id) do
    from(r in Role,
      join: ur in UserRole,
      on: ur.role_id == r.id,
      where: ur.user_id == ^user_id,
      order_by: [desc: r.system, asc: r.name]
    )
    |> Repo.all()
  end

  defp root_admin?(user_id) do
    case Repo.get(Liteskill.Accounts.User, user_id) do
      %{email: email} ->
        email == @root_admin_email

      # coveralls-ignore-start
      nil ->
        false
        # coveralls-ignore-stop
    end
  end

  # --- Group role assignments ---

  def assign_role_to_group(group_id, role_id) do
    %GroupRole{}
    |> GroupRole.changeset(%{group_id: group_id, role_id: role_id})
    |> Repo.insert()
  end

  def remove_role_from_group(group_id, role_id) do
    case Repo.one(
           from gr in GroupRole, where: gr.group_id == ^group_id and gr.role_id == ^role_id
         ) do
      nil -> {:error, :not_found}
      group_role -> Repo.delete(group_role)
    end
  end

  def list_group_roles(group_id) do
    from(r in Role,
      join: gr in GroupRole,
      on: gr.role_id == r.id,
      where: gr.group_id == ^group_id,
      order_by: [desc: r.system, asc: r.name]
    )
    |> Repo.all()
  end

  # --- Query helpers for admin UI ---

  def list_role_users(role_id) do
    from(u in Liteskill.Accounts.User,
      join: ur in UserRole,
      on: ur.user_id == u.id,
      where: ur.role_id == ^role_id,
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  def list_role_groups(role_id) do
    from(g in Liteskill.Groups.Group,
      join: gr in GroupRole,
      on: gr.group_id == g.id,
      where: gr.role_id == ^role_id,
      order_by: [asc: g.name]
    )
    |> Repo.all()
  end
end
