defmodule Liteskill.AuthorizationTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Authorization
  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.Groups

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "auth-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner User",
        oidc_sub: "owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "auth-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, viewer} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "auth-viewer-#{System.unique_integer([:positive])}@example.com",
        name: "Viewer User",
        oidc_sub: "viewer-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    entity_id = Ecto.UUID.generate()
    entity_type = "conversation"

    %{user: user, other: other, viewer: viewer, entity_id: entity_id, entity_type: entity_type}
  end

  describe "create_owner_acl/3" do
    test "creates an owner ACL entry", %{user: user, entity_id: eid, entity_type: etype} do
      assert {:ok, acl} = Authorization.create_owner_acl(etype, eid, user.id)
      assert acl.role == "owner"
      assert acl.entity_type == etype
      assert acl.entity_id == eid
      assert acl.user_id == user.id
    end

    test "rejects duplicate owner ACL", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert {:error, changeset} = Authorization.create_owner_acl(etype, eid, user.id)
      assert changeset.errors != []
    end
  end

  describe "has_access?/3" do
    test "returns true for direct user ACL", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert Authorization.has_access?(etype, eid, user.id)
    end

    test "returns false for no access", %{other: other, entity_id: eid, entity_type: etype} do
      refute Authorization.has_access?(etype, eid, other.id)
    end

    test "returns true for group-based access", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, group} = Groups.create_group("Test Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)

      {:ok, _} = Authorization.grant_group_access(etype, eid, user.id, group.id, "viewer")
      assert Authorization.has_access?(etype, eid, other.id)
    end
  end

  describe "get_role/3" do
    test "returns owner role", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert {:ok, "owner"} = Authorization.get_role(etype, eid, user.id)
    end

    test "returns viewer role", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")
      assert {:ok, "viewer"} = Authorization.get_role(etype, eid, other.id)
    end

    test "returns manager role", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")
      assert {:ok, "manager"} = Authorization.get_role(etype, eid, other.id)
    end

    test "returns highest role across user + group ACLs", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      # Grant viewer directly
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")
      # Grant manager via group
      {:ok, group} = Groups.create_group("Manager Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)
      {:ok, _} = Authorization.grant_group_access(etype, eid, user.id, group.id, "manager")

      # Should return the highest (manager > viewer)
      assert {:ok, "manager"} = Authorization.get_role(etype, eid, other.id)
    end

    test "returns no_access for unknown user", %{entity_id: eid, entity_type: etype} do
      assert {:error, :no_access} = Authorization.get_role(etype, eid, Ecto.UUID.generate())
    end
  end

  describe "can_manage?/3" do
    test "true for owner", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert Authorization.can_manage?(etype, eid, user.id)
    end

    test "true for manager", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")
      assert Authorization.can_manage?(etype, eid, other.id)
    end

    test "false for viewer", %{user: user, viewer: viewer, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, viewer.id, "viewer")
      refute Authorization.can_manage?(etype, eid, viewer.id)
    end

    test "false for no access", %{other: other, entity_id: eid, entity_type: etype} do
      refute Authorization.can_manage?(etype, eid, other.id)
    end
  end

  describe "is_owner?/3" do
    test "true for owner", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert Authorization.is_owner?(etype, eid, user.id)
    end

    test "false for manager", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")
      refute Authorization.is_owner?(etype, eid, other.id)
    end
  end

  describe "grant_access/5" do
    setup %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      :ok
    end

    test "owner can grant viewer", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      assert {:ok, acl} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")
      assert acl.role == "viewer"
    end

    test "owner can grant manager", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      assert {:ok, acl} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")
      assert acl.role == "manager"
    end

    test "nobody can grant owner", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      assert {:error, :cannot_grant_owner} =
               Authorization.grant_access(etype, eid, user.id, other.id, "owner")
    end

    test "manager can grant viewer", %{
      user: user,
      other: other,
      viewer: viewer,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")
      assert {:ok, acl} = Authorization.grant_access(etype, eid, other.id, viewer.id, "viewer")
      assert acl.role == "viewer"
    end

    test "viewer cannot grant", %{
      user: user,
      other: other,
      viewer: viewer,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, viewer.id, "viewer")

      assert {:error, :forbidden} =
               Authorization.grant_access(etype, eid, viewer.id, other.id, "viewer")
    end

    test "non-member cannot grant", %{
      other: other,
      viewer: viewer,
      entity_id: eid,
      entity_type: etype
    } do
      assert {:error, :no_access} =
               Authorization.grant_access(etype, eid, other.id, viewer.id, "viewer")
    end
  end

  describe "grant_group_access/5" do
    test "owner can grant group access", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, group} = Groups.create_group("Test Group", user.id)

      assert {:ok, acl} =
               Authorization.grant_group_access(etype, eid, user.id, group.id, "viewer")

      assert acl.group_id == group.id
      assert acl.role == "viewer"
    end

    test "cannot grant owner role to group", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, group} = Groups.create_group("Test Group", user.id)

      assert {:error, :cannot_grant_owner} =
               Authorization.grant_group_access(etype, eid, user.id, group.id, "owner")
    end
  end

  describe "update_role/5" do
    test "owner can change viewer to manager", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")

      assert {:ok, acl} = Authorization.update_role(etype, eid, user.id, other.id, "manager")
      assert acl.role == "manager"
    end

    test "cannot change owner role", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")

      assert {:error, :cannot_modify_owner} =
               Authorization.update_role(etype, eid, other.id, user.id, "manager")
    end

    test "returns not_found for non-existent ACL", %{
      user: user,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)

      assert {:error, :not_found} =
               Authorization.update_role(etype, eid, user.id, Ecto.UUID.generate(), "viewer")
    end
  end

  describe "revoke_access/4" do
    setup %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")
      :ok
    end

    test "owner can revoke viewer", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      assert {:ok, _} = Authorization.revoke_access(etype, eid, user.id, other.id)
      refute Authorization.has_access?(etype, eid, other.id)
    end

    test "cannot revoke owner", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      assert {:error, :cannot_revoke_owner} =
               Authorization.revoke_access(etype, eid, other.id, user.id)
    end

    test "returns not_found for non-existent ACL", %{
      user: user,
      entity_id: eid,
      entity_type: etype
    } do
      assert {:error, :not_found} =
               Authorization.revoke_access(etype, eid, user.id, Ecto.UUID.generate())
    end

    test "viewer cannot revoke", %{
      user: user,
      other: other,
      viewer: viewer,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, viewer.id, "viewer")

      assert {:error, :no_access} =
               Authorization.revoke_access(etype, eid, Ecto.UUID.generate(), other.id)
    end
  end

  describe "revoke_group_access/4" do
    test "owner can revoke group access", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, group} = Groups.create_group("Test Group", user.id)
      {:ok, _} = Authorization.grant_group_access(etype, eid, user.id, group.id, "viewer")

      assert {:ok, _} = Authorization.revoke_group_access(etype, eid, user.id, group.id)
    end

    test "returns not_found for non-existent group ACL", %{
      user: user,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)

      assert {:error, :not_found} =
               Authorization.revoke_group_access(etype, eid, user.id, Ecto.UUID.generate())
    end
  end

  describe "leave/3" do
    test "viewer can leave", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")

      assert {:ok, _} = Authorization.leave(etype, eid, other.id)
      refute Authorization.has_access?(etype, eid, other.id)
    end

    test "manager can leave", %{user: user, other: other, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "manager")

      assert {:ok, _} = Authorization.leave(etype, eid, other.id)
    end

    test "owner cannot leave", %{user: user, entity_id: eid, entity_type: etype} do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      assert {:error, :owner_cannot_leave} = Authorization.leave(etype, eid, user.id)
    end

    test "returns not_found for non-member", %{entity_id: eid, entity_type: etype} do
      assert {:error, :not_found} = Authorization.leave(etype, eid, Ecto.UUID.generate())
    end
  end

  describe "list_acls/2" do
    test "returns all ACLs for entity", %{
      user: user,
      other: other,
      entity_id: eid,
      entity_type: etype
    } do
      {:ok, _} = Authorization.create_owner_acl(etype, eid, user.id)
      {:ok, _} = Authorization.grant_access(etype, eid, user.id, other.id, "viewer")

      acls = Authorization.list_acls(etype, eid)
      assert length(acls) == 2
      roles = Enum.map(acls, & &1.role)
      assert "owner" in roles
      assert "viewer" in roles
    end

    test "returns empty list for no ACLs", %{entity_id: eid, entity_type: etype} do
      assert [] = Authorization.list_acls(etype, eid)
    end
  end

  describe "accessible_entity_ids/2" do
    test "returns entity ids accessible by user", %{user: user, entity_type: etype} do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()
      id3 = Ecto.UUID.generate()

      {:ok, _} = Authorization.create_owner_acl(etype, id1, user.id)
      {:ok, _} = Authorization.create_owner_acl(etype, id2, user.id)
      # id3 not accessible

      query = Authorization.accessible_entity_ids(etype, user.id)
      ids = Repo.all(query)

      assert id1 in ids
      assert id2 in ids
      refute id3 in ids
    end

    test "includes group-based access", %{user: user, other: other, entity_type: etype} do
      entity_id = Ecto.UUID.generate()
      {:ok, _} = Authorization.create_owner_acl(etype, entity_id, user.id)

      {:ok, group} = Groups.create_group("Query Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)
      {:ok, _} = Authorization.grant_group_access(etype, entity_id, user.id, group.id, "viewer")

      query = Authorization.accessible_entity_ids(etype, other.id)
      ids = Repo.all(query)
      assert entity_id in ids
    end
  end

  describe "can_edit?/3" do
    test "true for editor", %{user: user, other: other, entity_id: eid} do
      {:ok, _} = Authorization.create_owner_acl("wiki_space", eid, user.id)
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "editor")
      assert Authorization.can_edit?("wiki_space", eid, other.id)
    end

    test "true for manager", %{user: user, other: other, entity_id: eid} do
      {:ok, _} = Authorization.create_owner_acl("wiki_space", eid, user.id)
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "manager")
      assert Authorization.can_edit?("wiki_space", eid, other.id)
    end

    test "true for owner", %{user: user, entity_id: eid} do
      {:ok, _} = Authorization.create_owner_acl("wiki_space", eid, user.id)
      assert Authorization.can_edit?("wiki_space", eid, user.id)
    end

    test "false for viewer", %{user: user, viewer: viewer, entity_id: eid} do
      {:ok, _} = Authorization.create_owner_acl("wiki_space", eid, user.id)
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, viewer.id, "viewer")
      refute Authorization.can_edit?("wiki_space", eid, viewer.id)
    end

    test "false for no access", %{other: other, entity_id: eid} do
      refute Authorization.can_edit?("wiki_space", eid, other.id)
    end
  end

  describe "wiki_space grant permissions" do
    setup %{user: user, entity_id: eid} do
      {:ok, _} = Authorization.create_owner_acl("wiki_space", eid, user.id)
      :ok
    end

    test "owner can grant editor", %{user: user, other: other, entity_id: eid} do
      assert {:ok, acl} =
               Authorization.grant_access("wiki_space", eid, user.id, other.id, "editor")

      assert acl.role == "editor"
    end

    test "owner can grant manager", %{user: user, other: other, entity_id: eid} do
      assert {:ok, acl} =
               Authorization.grant_access("wiki_space", eid, user.id, other.id, "manager")

      assert acl.role == "manager"
    end

    test "owner can grant viewer", %{user: user, other: other, entity_id: eid} do
      assert {:ok, acl} =
               Authorization.grant_access("wiki_space", eid, user.id, other.id, "viewer")

      assert acl.role == "viewer"
    end

    test "manager can grant viewer", %{user: user, other: other, viewer: viewer, entity_id: eid} do
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "manager")

      assert {:ok, acl} =
               Authorization.grant_access("wiki_space", eid, other.id, viewer.id, "viewer")

      assert acl.role == "viewer"
    end

    test "manager can grant editor", %{user: user, other: other, viewer: viewer, entity_id: eid} do
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "manager")

      assert {:ok, acl} =
               Authorization.grant_access("wiki_space", eid, other.id, viewer.id, "editor")

      assert acl.role == "editor"
    end

    test "manager cannot grant manager", %{
      user: user,
      other: other,
      viewer: viewer,
      entity_id: eid
    } do
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "manager")

      assert {:error, :forbidden} =
               Authorization.grant_access("wiki_space", eid, other.id, viewer.id, "manager")
    end

    test "editor cannot grant anyone", %{user: user, other: other, viewer: viewer, entity_id: eid} do
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "editor")

      assert {:error, :forbidden} =
               Authorization.grant_access("wiki_space", eid, other.id, viewer.id, "viewer")
    end

    test "highest role returns editor correctly", %{user: user, other: other, entity_id: eid} do
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "editor")
      assert {:ok, "editor"} = Authorization.get_role("wiki_space", eid, other.id)
    end

    test "editor is higher than viewer", %{user: user, other: other, entity_id: eid} do
      # Grant viewer directly
      {:ok, _} = Authorization.grant_access("wiki_space", eid, user.id, other.id, "viewer")
      # Grant editor via group
      {:ok, group} = Groups.create_group("Editor Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)

      {:ok, _} =
        Authorization.grant_group_access("wiki_space", eid, user.id, group.id, "editor")

      assert {:ok, "editor"} = Authorization.get_role("wiki_space", eid, other.id)
    end
  end

  describe "verify_ownership/3" do
    test "returns :ok when user owns a conversation", %{user: user} do
      {:ok, conversation} =
        Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Owned"})

      assert :ok =
               Authorization.verify_ownership(
                 Liteskill.Chat.Conversation,
                 conversation.id,
                 user.id
               )
    end

    test "returns :error when user does not own a conversation", %{user: user, other: other} do
      {:ok, conversation} =
        Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Not Mine"})

      assert :error =
               Authorization.verify_ownership(
                 Liteskill.Chat.Conversation,
                 conversation.id,
                 other.id
               )
    end

    test "returns :error for non-existent entity", %{user: user} do
      assert :error =
               Authorization.verify_ownership(
                 Liteskill.Chat.Conversation,
                 Ecto.UUID.generate(),
                 user.id
               )
    end

    test "returns :ok when user owns an MCP server", %{user: user} do
      {:ok, server} =
        Liteskill.McpServers.create_server(%{
          name: "Mine",
          url: "https://mine.example.com",
          user_id: user.id
        })

      assert :ok =
               Authorization.verify_ownership(
                 Liteskill.McpServers.McpServer,
                 server.id,
                 user.id
               )
    end

    test "returns :error when user does not own an MCP server", %{user: user, other: other} do
      {:ok, server} =
        Liteskill.McpServers.create_server(%{
          name: "Theirs",
          url: "https://theirs.example.com",
          user_id: user.id
        })

      assert :error =
               Authorization.verify_ownership(
                 Liteskill.McpServers.McpServer,
                 server.id,
                 other.id
               )
    end
  end

  describe "EntityAcl schema" do
    test "validates entity_type inclusion" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "invalid",
          entity_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: "viewer"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :entity_type)
    end

    test "validates role inclusion" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "conversation",
          entity_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: "superadmin"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :role)
    end

    test "requires user_id or group_id" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "conversation",
          entity_id: Ecto.UUID.generate(),
          role: "viewer"
        })

      refute changeset.valid?
    end

    test "rejects both user_id and group_id" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "conversation",
          entity_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          group_id: Ecto.UUID.generate(),
          role: "viewer"
        })

      refute changeset.valid?
    end

    test "editor is a valid role" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "wiki_space",
          entity_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: "editor"
        })

      assert changeset.valid?
    end

    test "works for all entity types" do
      for etype <- ["conversation", "report", "source", "mcp_server", "wiki_space"] do
        changeset =
          EntityAcl.changeset(%EntityAcl{}, %{
            entity_type: etype,
            entity_id: Ecto.UUID.generate(),
            user_id: Ecto.UUID.generate(),
            role: "viewer"
          })

        assert changeset.valid?, "Expected valid changeset for entity_type: #{etype}"
      end
    end
  end
end
