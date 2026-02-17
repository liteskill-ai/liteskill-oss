defmodule Liteskill.Teams do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Authorization, Liteskill.Rbac],
    exports: [TeamDefinition, TeamMember]

  @moduledoc """
  Context for managing team definitions.

  Teams are named collections of agents with shared context and execution topology.
  """

  alias Liteskill.Teams.{TeamDefinition, TeamMember}
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_team(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "teams:create") do
      %TeamDefinition{}
      |> TeamDefinition.changeset(attrs)
      |> Authorization.create_with_owner_acl("team_definition", team_members: :agent_definition)
    end
  end

  def update_team(id, user_id, attrs) do
    case Repo.get(TeamDefinition, id) do
      nil ->
        {:error, :not_found}

      team ->
        with {:ok, team} <- authorize_owner(team, user_id) do
          team
          |> TeamDefinition.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, team_members: :agent_definition)}
            error -> error
          end
        end
    end
  end

  def delete_team(id, user_id) do
    case Repo.get(TeamDefinition, id) do
      nil ->
        {:error, :not_found}

      team ->
        with {:ok, team} <- authorize_owner(team, user_id) do
          Repo.delete(team)
        end
    end
  end

  # --- Queries ---

  def list_teams(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("team_definition", user_id)

    TeamDefinition
    |> where([t], t.user_id == ^user_id or t.id in subquery(accessible_ids))
    |> order_by([t], asc: t.name)
    |> preload(team_members: :agent_definition)
    |> Repo.all()
  end

  def get_team(id, user_id) do
    case Repo.get(TeamDefinition, id) |> Repo.preload(team_members: :agent_definition) do
      nil ->
        {:error, :not_found}

      %TeamDefinition{user_id: ^user_id} = team ->
        {:ok, team}

      %TeamDefinition{} = team ->
        if Authorization.has_access?("team_definition", team.id, user_id) do
          {:ok, team}
        else
          {:error, :not_found}
        end
    end
  end

  def get_team!(id) do
    Repo.get!(TeamDefinition, id) |> Repo.preload(team_members: :agent_definition)
  end

  # --- Member Management ---

  def add_member(team_definition_id, agent_definition_id, user_id, attrs \\ %{}) do
    with {:ok, _team} <- authorize_team_owner(team_definition_id, user_id) do
      next_position =
        from(tm in TeamMember,
          where: tm.team_definition_id == ^team_definition_id,
          select: coalesce(max(tm.position), -1) + 1
        )
        |> Repo.one()

      %TeamMember{}
      |> TeamMember.changeset(
        Map.merge(attrs, %{
          team_definition_id: team_definition_id,
          agent_definition_id: agent_definition_id,
          position: Map.get(attrs, :position, next_position)
        })
      )
      |> Repo.insert()
    end
  end

  def remove_member(team_definition_id, agent_definition_id, user_id) do
    with {:ok, _team} <- authorize_team_owner(team_definition_id, user_id) do
      case Repo.one(
             from(tm in TeamMember,
               where:
                 tm.team_definition_id == ^team_definition_id and
                   tm.agent_definition_id == ^agent_definition_id
             )
           ) do
        nil -> {:error, :not_found}
        member -> Repo.delete(member)
      end
    end
  end

  def update_member(member_id, user_id, attrs) do
    case Repo.get(TeamMember, member_id) |> Repo.preload(:team_definition) do
      nil ->
        {:error, :not_found}

      member ->
        with {:ok, _team} <- authorize_owner(member.team_definition, user_id) do
          member |> TeamMember.changeset(attrs) |> Repo.update()
        end
    end
  end

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)

  defp authorize_team_owner(team_definition_id, user_id) do
    case Repo.get(TeamDefinition, team_definition_id) do
      nil -> {:error, :not_found}
      team -> authorize_owner(team, user_id)
    end
  end
end
