defmodule Liteskill.Groups do
  use Boundary, top_level?: true, deps: [], exports: [Group, GroupMembership]

  @moduledoc """
  The Groups context. Manages groups and their memberships.
  """

  alias Liteskill.Groups.{Group, GroupMembership}
  alias Liteskill.Repo

  import Ecto.Query

  def create_group(name, creator_id) do
    Repo.transaction(fn ->
      group =
        %Group{}
        |> Group.changeset(%{name: name, created_by: creator_id})
        |> Repo.insert!()

      %GroupMembership{}
      |> GroupMembership.changeset(%{group_id: group.id, user_id: creator_id, role: "owner"})
      |> Repo.insert!()

      group
    end)
  end

  def list_groups(user_id) do
    Group
    |> join(:inner, [g], gm in GroupMembership, on: gm.group_id == g.id)
    |> where([_g, gm], gm.user_id == ^user_id)
    |> Repo.all()
  end

  def get_group(id, user_id) do
    group = Repo.get(Group, id)

    cond do
      is_nil(group) ->
        {:error, :not_found}

      member?(group.id, user_id) ->
        {:ok, group}

      true ->
        {:error, :not_found}
    end
  end

  def add_member(group_id, requester_id, target_user_id, role \\ "member") do
    with {:ok, group} <- authorize_creator(group_id, requester_id) do
      %GroupMembership{}
      |> GroupMembership.changeset(%{group_id: group.id, user_id: target_user_id, role: role})
      |> Repo.insert()
    end
  end

  def remove_member(group_id, requester_id, target_user_id) do
    with {:ok, group} <- authorize_creator(group_id, requester_id) do
      case Repo.one(
             from gm in GroupMembership,
               where: gm.group_id == ^group.id and gm.user_id == ^target_user_id
           ) do
        nil ->
          {:error, :not_found}

        %GroupMembership{role: "owner"} ->
          {:error, :cannot_remove_owner}

        membership ->
          Repo.delete(membership)
      end
    end
  end

  def leave_group(group_id, user_id) do
    case Repo.one(
           from gm in GroupMembership,
             where: gm.group_id == ^group_id and gm.user_id == ^user_id
         ) do
      nil ->
        {:error, :not_found}

      %GroupMembership{role: "owner"} ->
        {:error, :creator_cannot_leave}

      membership ->
        Repo.delete(membership)
    end
  end

  def delete_group(group_id, user_id) do
    with {:ok, group} <- authorize_creator(group_id, user_id) do
      Repo.delete(group)
    end
  end

  # Admin functions — bypass creator/membership checks

  def list_all_groups do
    Group
    |> order_by(:name)
    |> preload([:memberships, :creator])
    |> Repo.all()
  end

  def admin_get_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  def admin_get_group_by_name(name) do
    Repo.one(from g in Group, where: g.name == ^name)
  end

  def admin_list_members(group_id) do
    GroupMembership
    |> where([gm], gm.group_id == ^group_id)
    |> preload(:user)
    |> Repo.all()
  end

  def admin_add_member(group_id, user_id, role \\ "member") do
    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  def admin_remove_member(group_id, user_id) do
    case Repo.one(
           from gm in GroupMembership,
             where: gm.group_id == ^group_id and gm.user_id == ^user_id
         ) do
      nil -> {:error, :not_found}
      membership -> Repo.delete(membership)
    end
  end

  def admin_delete_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :not_found}
      group -> Repo.delete(group)
    end
  end

  defp authorize_creator(group_id, user_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, :not_found}

      %Group{created_by: ^user_id} = group ->
        {:ok, group}

      _ ->
        {:error, :forbidden}
    end
  end

  defp member?(group_id, user_id) do
    Repo.exists?(
      from gm in GroupMembership,
        where: gm.group_id == ^group_id and gm.user_id == ^user_id
    )
  end
end
