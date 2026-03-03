defmodule Liteskill.GroupsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Groups
  alias Liteskill.Groups.GroupMembership

  setup do
    {:ok, creator} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "creator-#{System.unique_integer([:positive])}@example.com",
        name: "Creator",
        oidc_sub: "creator-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, member} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        name: "Member",
        oidc_sub: "member-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, outsider} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "outsider-#{System.unique_integer([:positive])}@example.com",
        name: "Outsider",
        oidc_sub: "outsider-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{creator: creator, member: member, outsider: outsider}
  end

  describe "create_group/2" do
    test "creates group with owner membership", %{creator: creator} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert group.name == "My Group"
      assert group.created_by == creator.id

      # Verify owner membership
      membership =
        Repo.one!(
          from gm in GroupMembership,
            where: gm.group_id == ^group.id and gm.user_id == ^creator.id
        )

      assert membership.role == "owner"
    end
  end

  describe "list_groups/1" do
    test "lists groups where user is a member", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("Group 1", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      groups = Groups.list_groups(member.id)
      assert length(groups) == 1
      assert hd(groups).id == group.id
    end

    test "does not list groups where user is not a member", %{
      creator: creator,
      outsider: outsider
    } do
      {:ok, _} = Groups.create_group("Private Group", creator.id)

      assert Groups.list_groups(outsider.id) == []
    end
  end

  describe "get_group/2" do
    test "returns group for a member", %{creator: creator} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:ok, found} = Groups.get_group(group.id, creator.id)
      assert found.id == group.id
    end

    test "returns not_found for non-member", %{creator: creator, outsider: outsider} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:error, :not_found} = Groups.get_group(group.id, outsider.id)
    end

    test "returns not_found for nonexistent group", %{creator: creator} do
      assert {:error, :not_found} = Groups.get_group(Ecto.UUID.generate(), creator.id)
    end
  end

  describe "add_member/4" do
    test "adds a member to a group", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:ok, membership} = Groups.add_member(group.id, creator.id, member.id)
      assert membership.role == "member"
      assert membership.user_id == member.id
    end

    test "returns forbidden for non-creator", %{
      creator: creator,
      member: member,
      outsider: outsider
    } do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:error, :forbidden} = Groups.add_member(group.id, member.id, outsider.id)
    end

    test "returns error for duplicate membership", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:error, %Ecto.Changeset{}} = Groups.add_member(group.id, creator.id, member.id)
    end
  end

  describe "remove_member/3" do
    test "removes a member from a group", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:ok, _} = Groups.remove_member(group.id, creator.id, member.id)

      # Verify membership is gone
      assert Groups.list_groups(member.id) == []
    end

    test "cannot remove owner", %{creator: creator} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:error, :cannot_remove_owner} =
               Groups.remove_member(group.id, creator.id, creator.id)
    end

    test "returns not_found for non-member target", %{creator: creator, outsider: outsider} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:error, :not_found} = Groups.remove_member(group.id, creator.id, outsider.id)
    end

    test "returns forbidden for non-creator requester", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:error, :forbidden} = Groups.remove_member(group.id, member.id, creator.id)
    end
  end

  describe "leave_group/2" do
    test "member can leave a group", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:ok, _} = Groups.leave_group(group.id, member.id)
      assert Groups.list_groups(member.id) == []
    end

    test "creator cannot leave", %{creator: creator} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:error, :creator_cannot_leave} = Groups.leave_group(group.id, creator.id)
    end

    test "returns not_found for non-member", %{outsider: outsider} do
      assert {:error, :not_found} = Groups.leave_group(Ecto.UUID.generate(), outsider.id)
    end
  end

  describe "delete_group/2" do
    test "creator can delete group", %{creator: creator} do
      {:ok, group} = Groups.create_group("My Group", creator.id)

      assert {:ok, _} = Groups.delete_group(group.id, creator.id)
      assert Groups.list_groups(creator.id) == []
    end

    test "non-creator cannot delete", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("My Group", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:error, :forbidden} = Groups.delete_group(group.id, member.id)
    end

    test "returns not_found for nonexistent group", %{creator: creator} do
      assert {:error, :not_found} = Groups.delete_group(Ecto.UUID.generate(), creator.id)
    end
  end

  describe "list_all_groups/0" do
    test "lists all groups with preloaded associations", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("All Groups Test", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      results = Groups.list_all_groups()
      entry = Enum.find(results, fn g -> g.id == group.id end)

      assert entry
      assert entry.name == "All Groups Test"
      assert length(entry.memberships) == 2
      assert entry.creator.id == creator.id
    end

    test "returns empty list when no groups exist" do
      # Delete all groups first
      Repo.delete_all(GroupMembership)
      Repo.delete_all(Liteskill.Groups.Group)

      assert Groups.list_all_groups() == []
    end
  end

  describe "admin_get_group/1" do
    test "returns group without membership check", %{creator: creator} do
      {:ok, group} = Groups.create_group("Admin Get", creator.id)

      assert {:ok, found} = Groups.admin_get_group(group.id)
      assert found.id == group.id
    end

    test "returns not_found for nonexistent group" do
      assert {:error, :not_found} = Groups.admin_get_group(Ecto.UUID.generate())
    end
  end

  describe "admin_list_members/1" do
    test "lists members with preloaded user", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("Admin Members", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      members = Groups.admin_list_members(group.id)
      assert length(members) == 2
      assert Enum.all?(members, fn m -> m.user != nil end)

      user_ids = Enum.map(members, & &1.user_id)
      assert creator.id in user_ids
      assert member.id in user_ids
    end
  end

  describe "admin_add_member/3" do
    test "adds member without creator check", %{creator: creator, outsider: outsider} do
      {:ok, group} = Groups.create_group("Admin Add", creator.id)

      assert {:ok, membership} = Groups.admin_add_member(group.id, outsider.id, "member")
      assert membership.user_id == outsider.id
      assert membership.role == "member"
    end
  end

  describe "admin_remove_member/2" do
    test "removes member without creator check", %{creator: creator, member: member} do
      {:ok, group} = Groups.create_group("Admin Remove", creator.id)
      {:ok, _} = Groups.add_member(group.id, creator.id, member.id)

      assert {:ok, _} = Groups.admin_remove_member(group.id, member.id)
      assert Groups.list_groups(member.id) == []
    end

    test "returns not_found for non-member", %{creator: creator, outsider: outsider} do
      {:ok, group} = Groups.create_group("Admin Remove NF", creator.id)

      assert {:error, :not_found} = Groups.admin_remove_member(group.id, outsider.id)
    end
  end

  describe "admin_get_group_by_name/1" do
    test "returns group by name", %{creator: creator} do
      {:ok, group} = Groups.create_group("Findable Group", creator.id)

      found = Groups.admin_get_group_by_name("Findable Group")
      assert found.id == group.id
    end

    test "returns nil for nonexistent name" do
      assert is_nil(Groups.admin_get_group_by_name("Nonexistent"))
    end
  end

  describe "admin_delete_group/1" do
    test "deletes group without creator check", %{creator: creator} do
      {:ok, group} = Groups.create_group("Admin Delete", creator.id)

      assert {:ok, _} = Groups.admin_delete_group(group.id)
      assert Groups.list_groups(creator.id) == []
    end

    test "returns not_found for nonexistent group" do
      assert {:error, :not_found} = Groups.admin_delete_group(Ecto.UUID.generate())
    end
  end
end
