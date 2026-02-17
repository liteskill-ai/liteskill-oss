defmodule Liteskill.RbacTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rbac
  alias Liteskill.Rbac.{Permissions, Role}
  alias Liteskill.Groups

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rbac-user-#{System.unique_integer([:positive])}@example.com",
        name: "RBAC User",
        oidc_sub: "rbac-user-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rbac-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "rbac-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user, other: other}
  end

  describe "ensure_system_roles/0" do
    test "creates system roles" do
      Rbac.ensure_system_roles()

      roles = Rbac.list_roles()
      names = Enum.map(roles, & &1.name)
      assert "Instance Admin" in names
      assert "Default" in names

      admin_role = Rbac.get_role_by_name!("Instance Admin")
      assert admin_role.system == true
      assert "*" in admin_role.permissions

      default_role = Rbac.get_role_by_name!("Default")
      assert default_role.system == true
      assert "conversations:create" in default_role.permissions
    end

    test "is idempotent" do
      Rbac.ensure_system_roles()
      Rbac.ensure_system_roles()

      roles = Repo.all(from r in Role, where: r.name == "Instance Admin")
      assert length(roles) == 1
    end

    test "migrates existing admin users" do
      # Create an admin user
      {:ok, admin} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "rbac-admin-#{System.unique_integer([:positive])}@example.com",
          name: "Admin",
          oidc_sub: "rbac-admin-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      admin
      |> Liteskill.Accounts.User.role_changeset(%{role: "admin"})
      |> Repo.update!()

      Rbac.ensure_system_roles()

      user_roles = Rbac.list_user_roles(admin.id)
      assert Enum.any?(user_roles, &(&1.name == "Instance Admin"))
    end
  end

  describe "has_permission?/2" do
    setup %{user: user} do
      Rbac.ensure_system_roles()
      %{user: user}
    end

    test "grants default permissions to all users", %{user: user} do
      assert Rbac.has_permission?(user.id, "conversations:create")
      assert Rbac.has_permission?(user.id, "agents:create")
    end

    test "denies non-default permissions", %{user: user} do
      refute Rbac.has_permission?(user.id, "admin:users:manage")
      refute Rbac.has_permission?(user.id, "conversations:delete_any")
    end

    test "grants permissions from direct role assignment", %{user: user} do
      {:ok, role} =
        Rbac.create_role(%{name: "Moderator", permissions: ["conversations:delete_any"]})

      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)

      assert Rbac.has_permission?(user.id, "conversations:delete_any")
    end

    test "grants permissions from group role assignment", %{user: user} do
      {:ok, group} = Groups.create_group("RBAC Group", user.id)

      {:ok, role} =
        Rbac.create_role(%{name: "Group Mod", permissions: ["conversations:view_all"]})

      {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)

      assert Rbac.has_permission?(user.id, "conversations:view_all")
    end

    test "wildcard grants everything", %{user: user} do
      admin_role = Rbac.get_role_by_name!("Instance Admin")
      {:ok, _} = Rbac.assign_role_to_user(user.id, admin_role.id)

      assert Rbac.has_permission?(user.id, "admin:users:manage")
      assert Rbac.has_permission?(user.id, "conversations:delete_any")
    end
  end

  describe "list_permissions/1" do
    setup %{user: user} do
      Rbac.ensure_system_roles()
      %{user: user}
    end

    test "merges all permission sources", %{user: user} do
      {:ok, role} = Rbac.create_role(%{name: "Extra", permissions: ["conversations:delete_any"]})
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)

      perms = Rbac.list_permissions(user.id)
      # From default role
      assert MapSet.member?(perms, "conversations:create")
      # From direct role
      assert MapSet.member?(perms, "conversations:delete_any")
    end

    test "wildcard expands to all permissions", %{user: user} do
      admin_role = Rbac.get_role_by_name!("Instance Admin")
      {:ok, _} = Rbac.assign_role_to_user(user.id, admin_role.id)

      perms = Rbac.list_permissions(user.id)
      assert MapSet.member?(perms, "*")
      # All permissions are included
      for perm <- Permissions.all_permissions() do
        assert MapSet.member?(perms, perm)
      end
    end
  end

  describe "authorize/2" do
    setup do
      Rbac.ensure_system_roles()
      :ok
    end

    test "returns :ok when permission is granted", %{user: user} do
      assert :ok = Rbac.authorize(user.id, "conversations:create")
    end

    test "returns {:error, :forbidden} when denied", %{user: user} do
      assert {:error, :forbidden} = Rbac.authorize(user.id, "admin:users:manage")
    end
  end

  describe "has_any_admin_permission?/1" do
    setup do
      Rbac.ensure_system_roles()
      :ok
    end

    test "returns false for normal user", %{user: user} do
      refute Rbac.has_any_admin_permission?(user.id)
    end

    test "returns true for user with admin:* permission", %{user: user} do
      {:ok, role} = Rbac.create_role(%{name: "Admin Viewer", permissions: ["admin:usage:view"]})
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert Rbac.has_any_admin_permission?(user.id)
    end

    test "returns true for user with wildcard", %{user: user} do
      admin_role = Rbac.get_role_by_name!("Instance Admin")
      {:ok, _} = Rbac.assign_role_to_user(user.id, admin_role.id)
      assert Rbac.has_any_admin_permission?(user.id)
    end

    test "returns true for llm_providers:manage", %{user: user} do
      {:ok, role} = Rbac.create_role(%{name: "LLM Admin", permissions: ["llm_providers:manage"]})
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert Rbac.has_any_admin_permission?(user.id)
    end

    test "returns true for groups:manage_all", %{user: user} do
      {:ok, role} = Rbac.create_role(%{name: "Group Admin", permissions: ["groups:manage_all"]})
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert Rbac.has_any_admin_permission?(user.id)
    end
  end

  describe "role CRUD" do
    setup do
      Rbac.ensure_system_roles()
      :ok
    end

    test "create_role/1 creates a custom role" do
      assert {:ok, role} =
               Rbac.create_role(%{name: "Custom", permissions: ["conversations:create"]})

      assert role.name == "Custom"
      assert role.system == false
      assert "conversations:create" in role.permissions
    end

    test "create_role/1 validates permissions" do
      assert {:error, changeset} = Rbac.create_role(%{name: "Bad", permissions: ["fake:perm"]})
      assert %{permissions: [_]} = errors_on(changeset)
    end

    test "create_role/1 rejects duplicate names" do
      {:ok, _} = Rbac.create_role(%{name: "Unique Role"})
      assert {:error, changeset} = Rbac.create_role(%{name: "Unique Role"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "update_role/2 updates custom role" do
      {:ok, role} = Rbac.create_role(%{name: "Updatable", permissions: []})
      assert {:ok, updated} = Rbac.update_role(role, %{permissions: ["agents:create"]})
      assert "agents:create" in updated.permissions
    end

    test "update_role/2 prevents renaming system roles" do
      role = Rbac.get_role_by_name!("Default")
      {:ok, updated} = Rbac.update_role(role, %{name: "Renamed", description: "Updated desc"})
      # Name should NOT be changed for system roles
      assert updated.name == "Default"
      assert updated.description == "Updated desc"
    end

    test "update_role/2 allows updating system role permissions" do
      role = Rbac.get_role_by_name!("Default")
      {:ok, updated} = Rbac.update_role(role, %{permissions: ["conversations:create"]})
      assert updated.permissions == ["conversations:create"]
    end

    test "delete_role/1 deletes custom role" do
      {:ok, role} = Rbac.create_role(%{name: "Deletable"})
      assert {:ok, _} = Rbac.delete_role(role)
      assert {:error, :not_found} = Rbac.get_role(role.id)
    end

    test "delete_role/1 refuses to delete system roles" do
      role = Rbac.get_role_by_name!("Default")
      assert {:error, :cannot_delete_system_role} = Rbac.delete_role(role)
    end

    test "list_roles/0 returns all roles with system roles first" do
      {:ok, _} = Rbac.create_role(%{name: "Custom Alpha"})
      roles = Rbac.list_roles()
      system_roles = Enum.take_while(roles, & &1.system)
      assert length(system_roles) >= 2
    end

    test "get_role/1 returns role by ID" do
      {:ok, role} = Rbac.create_role(%{name: "Gettable"})
      assert {:ok, found} = Rbac.get_role(role.id)
      assert found.id == role.id
    end

    test "get_role/1 returns error for missing ID" do
      assert {:error, :not_found} = Rbac.get_role(Ecto.UUID.generate())
    end
  end

  describe "user role assignments" do
    setup %{user: user} do
      Rbac.ensure_system_roles()
      {:ok, role} = Rbac.create_role(%{name: "Assignable-#{System.unique_integer([:positive])}"})
      %{user: user, role: role}
    end

    test "assign_role_to_user/2", %{user: user, role: role} do
      assert {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert Enum.any?(Rbac.list_user_roles(user.id), &(&1.id == role.id))
    end

    test "rejects duplicate assignment", %{user: user, role: role} do
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert {:error, _} = Rbac.assign_role_to_user(user.id, role.id)
    end

    test "remove_role_from_user/2", %{user: user, role: role} do
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      assert {:ok, _} = Rbac.remove_role_from_user(user.id, role.id)
      refute Enum.any?(Rbac.list_user_roles(user.id), &(&1.id == role.id))
    end

    test "remove returns error for non-existent assignment", %{user: user, role: role} do
      assert {:error, :not_found} = Rbac.remove_role_from_user(user.id, role.id)
    end

    test "list_user_roles/1", %{user: user, role: role} do
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      roles = Rbac.list_user_roles(user.id)
      assert roles != []
    end

    test "protects root admin from losing Instance Admin" do
      # Create or find the root admin
      admin = Liteskill.Accounts.ensure_admin_user()
      Rbac.ensure_system_roles()

      admin_role = Rbac.get_role_by_name!("Instance Admin")

      assert {:error, :cannot_remove_root_admin} =
               Rbac.remove_role_from_user(admin.id, admin_role.id)
    end
  end

  describe "group role assignments" do
    setup %{user: user} do
      Rbac.ensure_system_roles()
      {:ok, group} = Groups.create_group("RBAC Test Group", user.id)
      {:ok, role} = Rbac.create_role(%{name: "Group Role-#{System.unique_integer([:positive])}"})
      %{group: group, role: role}
    end

    test "assign_role_to_group/2", %{group: group, role: role} do
      assert {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)
      assert Enum.any?(Rbac.list_group_roles(group.id), &(&1.id == role.id))
    end

    test "rejects duplicate assignment", %{group: group, role: role} do
      {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)
      assert {:error, _} = Rbac.assign_role_to_group(group.id, role.id)
    end

    test "remove_role_from_group/2", %{group: group, role: role} do
      {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)
      assert {:ok, _} = Rbac.remove_role_from_group(group.id, role.id)
      refute Enum.any?(Rbac.list_group_roles(group.id), &(&1.id == role.id))
    end

    test "remove returns error for non-existent assignment", %{group: group, role: role} do
      assert {:error, :not_found} = Rbac.remove_role_from_group(group.id, role.id)
    end

    test "list_group_roles/1", %{group: group, role: role} do
      {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)
      roles = Rbac.list_group_roles(group.id)
      assert roles != []
    end
  end

  describe "list_role_users/1 and list_role_groups/1" do
    setup %{user: user} do
      Rbac.ensure_system_roles()
      {:ok, role} = Rbac.create_role(%{name: "Query Role-#{System.unique_integer([:positive])}"})
      %{user: user, role: role}
    end

    test "list_role_users/1 returns users assigned to a role", %{user: user, role: role} do
      {:ok, _} = Rbac.assign_role_to_user(user.id, role.id)
      users = Rbac.list_role_users(role.id)
      assert Enum.any?(users, &(&1.id == user.id))
    end

    test "list_role_groups/1 returns groups assigned to a role", %{user: user, role: role} do
      {:ok, group} = Groups.create_group("Role Group", user.id)
      {:ok, _} = Rbac.assign_role_to_group(group.id, role.id)
      groups = Rbac.list_role_groups(role.id)
      assert Enum.any?(groups, &(&1.id == group.id))
    end
  end
end
