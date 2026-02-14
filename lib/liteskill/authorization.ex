defmodule Liteskill.Authorization do
  @moduledoc """
  Centralized authorization context for all entity types.

  Provides access checks, role queries, ACL management, and composable
  query helpers that other contexts delegate to.

  Role hierarchy: viewer < editor < manager < owner
  - **viewer**: read-only access
  - **editor**: can edit content (wiki_space only)
  - **manager**: edit + grant/revoke viewer/editor/manager access
  - **owner**: full control (delete, demote anyone, transfer ownership)
  """

  alias Liteskill.Authorization.{EntityAcl, Roles}
  alias Liteskill.Groups.GroupMembership
  alias Liteskill.Repo

  import Ecto.Query

  # --- Access Checks ---

  @doc """
  Returns true if the user has any access to the entity
  (owner of the resource, direct ACL, or group-based ACL).
  """
  def has_access?(entity_type, entity_id, user_id) do
    Repo.exists?(
      from(a in EntityAcl,
        left_join: gm in GroupMembership,
        on: gm.group_id == a.group_id and gm.user_id == ^user_id,
        where:
          a.entity_type == ^entity_type and
            a.entity_id == ^entity_id and
            (a.user_id == ^user_id or not is_nil(gm.id))
      )
    )
  end

  @doc """
  Returns the highest role the user holds on the entity.
  Checks direct user ACL and group-based ACLs, returns the highest.
  """
  def get_role(entity_type, entity_id, user_id) do
    roles =
      from(a in EntityAcl,
        left_join: gm in GroupMembership,
        on: gm.group_id == a.group_id and gm.user_id == ^user_id,
        where:
          a.entity_type == ^entity_type and
            a.entity_id == ^entity_id and
            (a.user_id == ^user_id or not is_nil(gm.id)),
        select: a.role
      )
      |> Repo.all()

    case roles do
      [] -> {:error, :no_access}
      roles -> {:ok, Roles.highest(roles)}
    end
  end

  @doc "Returns true if user has manager or owner role."
  def can_manage?(entity_type, entity_id, user_id) do
    case get_role(entity_type, entity_id, user_id) do
      {:ok, role} -> role in ["manager", "owner"]
      _ -> false
    end
  end

  @doc "Returns true if user has editor, manager, or owner role."
  def can_edit?(entity_type, entity_id, user_id) do
    case get_role(entity_type, entity_id, user_id) do
      {:ok, role} -> role in ["editor", "manager", "owner"]
      _ -> false
    end
  end

  @doc "Returns true if user has owner role."
  def is_owner?(entity_type, entity_id, user_id) do
    case get_role(entity_type, entity_id, user_id) do
      {:ok, "owner"} -> true
      _ -> false
    end
  end

  # --- ACL Management ---

  @doc "Creates the initial owner ACL when a resource is created."
  def create_owner_acl(entity_type, entity_id, user_id) do
    %EntityAcl{}
    |> EntityAcl.changeset(%{
      entity_type: entity_type,
      entity_id: entity_id,
      user_id: user_id,
      role: "owner"
    })
    |> Repo.insert()
  end

  @doc """
  Grants access to a user. Grantor must be owner or manager.
  Managers cannot grant owner role. Nobody can grant owner role
  (ownership is only set at creation or via transfer).
  """
  def grant_access(entity_type, entity_id, grantor_id, grantee_user_id, role) do
    with {:ok, grantor_role} <- get_role(entity_type, entity_id, grantor_id),
         :ok <- validate_grant_permission(entity_type, grantor_role, role) do
      %EntityAcl{}
      |> EntityAcl.changeset(%{
        entity_type: entity_type,
        entity_id: entity_id,
        user_id: grantee_user_id,
        role: role
      })
      |> Repo.insert()
    end
  end

  @doc """
  Grants access to a group. Same permission rules as grant_access/5.
  """
  def grant_group_access(entity_type, entity_id, grantor_id, group_id, role) do
    with {:ok, grantor_role} <- get_role(entity_type, entity_id, grantor_id),
         :ok <- validate_grant_permission(entity_type, grantor_role, role) do
      %EntityAcl{}
      |> EntityAcl.changeset(%{
        entity_type: entity_type,
        entity_id: entity_id,
        group_id: group_id,
        role: role
      })
      |> Repo.insert()
    end
  end

  @doc """
  Updates the role of an existing ACL entry.
  Grantor must be owner or manager. Cannot change to/from owner.
  """
  def update_role(entity_type, entity_id, grantor_id, target_user_id, new_role) do
    with {:ok, grantor_role} <- get_role(entity_type, entity_id, grantor_id),
         :ok <- validate_grant_permission(entity_type, grantor_role, new_role) do
      case get_user_acl(entity_type, entity_id, target_user_id) do
        nil ->
          {:error, :not_found}

        %EntityAcl{role: "owner"} ->
          {:error, :cannot_modify_owner}

        acl ->
          acl
          |> EntityAcl.changeset(%{role: new_role})
          |> Repo.update()
      end
    end
  end

  @doc """
  Revokes a user's access. Revoker must be owner or manager.
  Cannot revoke owners. Managers can only revoke viewers and other managers.
  """
  def revoke_access(entity_type, entity_id, revoker_id, target_user_id) do
    with {:ok, revoker_role} <- get_role(entity_type, entity_id, revoker_id) do
      case get_user_acl(entity_type, entity_id, target_user_id) do
        nil ->
          {:error, :not_found}

        %EntityAcl{role: "owner"} ->
          {:error, :cannot_revoke_owner}

        %EntityAcl{} = acl ->
          if can_revoke?(revoker_role, acl.role) do
            Repo.delete(acl)
          else
            {:error, :forbidden}
          end
      end
    end
  end

  @doc """
  Revokes a group's access.
  """
  def revoke_group_access(entity_type, entity_id, revoker_id, group_id) do
    with {:ok, revoker_role} <- get_role(entity_type, entity_id, revoker_id) do
      case get_group_acl(entity_type, entity_id, group_id) do
        nil ->
          {:error, :not_found}

        # coveralls-ignore-start
        %EntityAcl{role: "owner"} ->
          {:error, :cannot_revoke_owner}

        # coveralls-ignore-stop

        %EntityAcl{} = acl ->
          if can_revoke?(revoker_role, acl.role) do
            Repo.delete(acl)
          else
            {:error, :forbidden}
          end
      end
    end
  end

  @doc "User leaves the entity. Owners cannot leave."
  def leave(entity_type, entity_id, user_id) do
    case get_user_acl(entity_type, entity_id, user_id) do
      nil -> {:error, :not_found}
      %EntityAcl{role: "owner"} -> {:error, :owner_cannot_leave}
      acl -> Repo.delete(acl)
    end
  end

  @doc "Lists all ACLs for an entity, preloading user and group."
  def list_acls(entity_type, entity_id) do
    from(a in EntityAcl,
      where: a.entity_type == ^entity_type and a.entity_id == ^entity_id,
      preload: [:user, :group],
      order_by: [desc: a.role, asc: a.inserted_at]
    )
    |> Repo.all()
  end

  # --- Query Helpers ---

  @doc """
  Returns a subquery of entity IDs the user can access for the given type.
  Used by other contexts to filter their list queries.
  """
  def accessible_entity_ids(entity_type, user_id) do
    direct =
      from(a in EntityAcl,
        where: a.entity_type == ^entity_type and a.user_id == ^user_id,
        select: a.entity_id
      )

    group =
      from(a in EntityAcl,
        join: gm in GroupMembership,
        on: gm.group_id == a.group_id and gm.user_id == ^user_id,
        where: a.entity_type == ^entity_type and not is_nil(a.group_id),
        select: a.entity_id
      )

    from(e in subquery(union_all(direct, ^group)), select: e.entity_id)
  end

  # --- Ownership Verification ---

  @schema_map %{
    "agent_definition" => Liteskill.Agents.AgentDefinition,
    "conversation" => Liteskill.Chat.Conversation,
    "data_source" => Liteskill.DataSources.Source,
    "instance" => Liteskill.Instances.Instance,
    "llm_model" => Liteskill.LlmModels.LlmModel,
    "llm_provider" => Liteskill.LlmProviders.LlmProvider,
    "mcp_server" => Liteskill.McpServers.McpServer,
    "schedule" => Liteskill.Schedules.Schedule,
    "team_definition" => Liteskill.Teams.TeamDefinition,
    "wiki_space" => Liteskill.DataSources.Document
  }

  @doc """
  Verifies that the user owns the given entity by checking the `user_id` field.
  Returns `:ok` if user owns it, `:error` otherwise.
  """
  def verify_ownership(entity_type, entity_id, user_id) do
    case Map.get(@schema_map, entity_type) do
      nil ->
        :error

      schema ->
        case Repo.get(schema, entity_id) do
          %{user_id: ^user_id} -> :ok
          _ -> :error
        end
    end
  end

  # --- Private Helpers ---

  defp get_user_acl(entity_type, entity_id, user_id) do
    Repo.one(
      from(a in EntityAcl,
        where:
          a.entity_type == ^entity_type and
            a.entity_id == ^entity_id and
            a.user_id == ^user_id
      )
    )
  end

  defp get_group_acl(entity_type, entity_id, group_id) do
    Repo.one(
      from(a in EntityAcl,
        where:
          a.entity_type == ^entity_type and
            a.entity_id == ^entity_id and
            a.group_id == ^group_id
      )
    )
  end

  defp validate_grant_permission(_entity_type, _grantor_role, "owner"),
    do: {:error, :cannot_grant_owner}

  # Wiki spaces: manager can grant viewer/editor; owner can grant viewer/editor/manager
  defp validate_grant_permission("wiki_space", "manager", role) when role in ["viewer", "editor"],
    do: :ok

  defp validate_grant_permission("wiki_space", "manager", _role), do: {:error, :forbidden}

  defp validate_grant_permission("wiki_space", "owner", _role), do: :ok

  # All other entity types: owner/manager can grant any non-owner role
  defp validate_grant_permission(_entity_type, grantor_role, _role)
       when grantor_role in ["owner", "manager"],
       do: :ok

  defp validate_grant_permission(_, _, _), do: {:error, :forbidden}

  defp can_revoke?(revoker_role, _target_role) when revoker_role in ["owner", "manager"], do: true
  # coveralls-ignore-next-line
  defp can_revoke?(_, _), do: false
end
