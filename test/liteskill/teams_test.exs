defmodule Liteskill.TeamsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Teams
  alias Liteskill.Teams.{TeamDefinition, TeamMember}
  alias Liteskill.Agents

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "teams-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Team Owner",
        oidc_sub: "teams-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "teams-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "teams-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Team Agent #{System.unique_integer([:positive])}",
        strategy: "react",
        user_id: owner.id
      })

    %{owner: owner, other: other, agent: agent}
  end

  defp team_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Team #{System.unique_integer([:positive])}",
        description: "A test team",
        shared_context: "Shared context for tests",
        topology: "pipeline",
        user_id: user.id
      },
      overrides
    )
  end

  describe "create_team/1" do
    test "creates a team with owner ACL", %{owner: owner} do
      attrs = team_attrs(owner)
      assert {:ok, team} = Teams.create_team(attrs)

      assert team.name == attrs.name
      assert team.description == "A test team"
      assert team.shared_context == "Shared context for tests"
      assert team.default_topology == "pipeline"
      assert team.aggregation_strategy == "last"
      assert team.status == "active"
      assert team.user_id == owner.id
      assert team.team_members == []

      assert Liteskill.Authorization.owner?("team_definition", team.id, owner.id)
    end

    test "rejects create without user_id" do
      assert {:error, :forbidden} = Teams.create_team(%{})
    end

    test "validates required fields", %{owner: owner} do
      assert {:error, changeset} = Teams.create_team(%{user_id: owner.id})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
    end

    test "validates topology inclusion", %{owner: owner} do
      attrs = team_attrs(owner, %{default_topology: "invalid"})
      assert {:error, changeset} = Teams.create_team(attrs)
      assert "is invalid" in errors_on(changeset).default_topology
    end

    test "validates aggregation_strategy inclusion", %{owner: owner} do
      attrs = team_attrs(owner, %{aggregation_strategy: "invalid"})
      assert {:error, changeset} = Teams.create_team(attrs)
      assert "is invalid" in errors_on(changeset).aggregation_strategy
    end

    test "validates status inclusion", %{owner: owner} do
      attrs = team_attrs(owner, %{status: "bogus"})
      assert {:error, changeset} = Teams.create_team(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "enforces unique name per user", %{owner: owner} do
      attrs = team_attrs(owner, %{name: "Unique Team"})
      assert {:ok, _} = Teams.create_team(attrs)
      assert {:error, changeset} = Teams.create_team(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "update_team/3" do
    test "updates team as owner", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:ok, updated} = Teams.update_team(team.id, owner.id, %{name: "Renamed Team"})
      assert updated.name == "Renamed Team"
    end

    test "returns not_found for missing team", %{owner: owner} do
      assert {:error, :not_found} = Teams.update_team(Ecto.UUID.generate(), owner.id, %{})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:error, :forbidden} = Teams.update_team(team.id, other.id, %{name: "Nope"})
    end

    test "preloads team_members on update", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, updated} = Teams.update_team(team.id, owner.id, %{description: "Updated"})
      assert is_list(updated.team_members)
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Teams.update_team(team.id, owner.id, %{default_topology: "invalid"})
    end
  end

  describe "delete_team/2" do
    test "deletes team as owner", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:ok, _} = Teams.delete_team(team.id, owner.id)
      assert {:error, :not_found} = Teams.get_team(team.id, owner.id)
    end

    test "returns not_found for missing team", %{owner: owner} do
      assert {:error, :not_found} = Teams.delete_team(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:error, :forbidden} = Teams.delete_team(team.id, other.id)
    end
  end

  describe "list_teams/1" do
    test "lists user's own teams", %{owner: owner} do
      {:ok, t1} = Teams.create_team(team_attrs(owner, %{name: "Alpha Team"}))
      {:ok, t2} = Teams.create_team(team_attrs(owner, %{name: "Beta Team"}))

      teams = Teams.list_teams(owner.id)
      ids = Enum.map(teams, & &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "returns empty for user with no teams", %{other: other} do
      assert Teams.list_teams(other.id) == []
    end

    test "includes teams shared via ACL", %{owner: owner, other: other} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      Liteskill.Authorization.grant_access(
        "team_definition",
        team.id,
        owner.id,
        other.id,
        "viewer"
      )

      teams = Teams.list_teams(other.id)
      assert length(teams) == 1
      assert hd(teams).id == team.id
    end
  end

  describe "get_team/2" do
    test "returns team for owner", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:ok, found} = Teams.get_team(team.id, owner.id)
      assert found.id == team.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Teams.get_team(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:error, :not_found} = Teams.get_team(team.id, other.id)
    end

    test "returns team for user with ACL", %{owner: owner, other: other} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      Liteskill.Authorization.grant_access(
        "team_definition",
        team.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Teams.get_team(team.id, other.id)
      assert found.id == team.id
    end
  end

  describe "get_team!/1" do
    test "returns team without auth check", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      found = Teams.get_team!(team.id)
      assert found.id == team.id
    end
  end

  describe "add_member/4" do
    test "adds a member with auto-incrementing position", %{owner: owner, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      assert {:ok, member} = Teams.add_member(team.id, agent.id, owner.id)
      assert member.team_definition_id == team.id
      assert member.agent_definition_id == agent.id
      assert member.position == 0
      assert member.role == "worker"
    end

    test "adds member with custom role and description", %{owner: owner, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      assert {:ok, member} =
               Teams.add_member(team.id, agent.id, owner.id, %{
                 role: "lead",
                 description: "Team lead"
               })

      assert member.role == "lead"
      assert member.description == "Team lead"
    end

    test "auto-increments position for subsequent members", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))

      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Agent Two #{System.unique_integer([:positive])}",
          strategy: "direct",
          user_id: owner.id
        })

      {:ok, agent3} =
        Agents.create_agent(%{
          name: "Agent Three #{System.unique_integer([:positive])}",
          strategy: "chain_of_thought",
          user_id: owner.id
        })

      {:ok, m1} = Teams.add_member(team.id, agent2.id, owner.id)
      {:ok, m2} = Teams.add_member(team.id, agent3.id, owner.id)

      assert m1.position == 0
      assert m2.position == 1
    end

    test "enforces unique agent per team", %{owner: owner, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, _} = Teams.add_member(team.id, agent.id, owner.id)
      assert {:error, changeset} = Teams.add_member(team.id, agent.id, owner.id)
      assert "has already been taken" in errors_on(changeset).team_definition_id
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:error, :forbidden} = Teams.add_member(team.id, agent.id, other.id)
    end

    test "returns not_found for missing team", %{owner: owner, agent: agent} do
      assert {:error, :not_found} = Teams.add_member(Ecto.UUID.generate(), agent.id, owner.id)
    end
  end

  describe "remove_member/3" do
    test "removes a member", %{owner: owner, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, _} = Teams.add_member(team.id, agent.id, owner.id)
      assert {:ok, _} = Teams.remove_member(team.id, agent.id, owner.id)

      {:ok, team} = Teams.get_team(team.id, owner.id)
      assert team.team_members == []
    end

    test "returns not_found for non-existent member", %{owner: owner} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      assert {:error, :not_found} = Teams.remove_member(team.id, Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, _} = Teams.add_member(team.id, agent.id, owner.id)
      assert {:error, :forbidden} = Teams.remove_member(team.id, agent.id, other.id)
    end
  end

  describe "update_member/3" do
    test "updates member attributes", %{owner: owner, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, member} = Teams.add_member(team.id, agent.id, owner.id)

      assert {:ok, updated} =
               Teams.update_member(member.id, owner.id, %{role: "analyst", position: 5})

      assert updated.role == "analyst"
      assert updated.position == 5
    end

    test "returns not_found for missing member", %{owner: owner} do
      assert {:error, :not_found} =
               Teams.update_member(Ecto.UUID.generate(), owner.id, %{role: "lead"})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other, agent: agent} do
      {:ok, team} = Teams.create_team(team_attrs(owner))
      {:ok, member} = Teams.add_member(team.id, agent.id, owner.id)

      assert {:error, :forbidden} =
               Teams.update_member(member.id, other.id, %{role: "analyst"})
    end
  end

  describe "TeamDefinition schema" do
    test "valid_topologies returns expected values" do
      assert "pipeline" in TeamDefinition.valid_topologies()
      assert "parallel" in TeamDefinition.valid_topologies()
    end

    test "valid_aggregations returns expected values" do
      assert "last" in TeamDefinition.valid_aggregations()
      assert "merge" in TeamDefinition.valid_aggregations()
      assert "vote" in TeamDefinition.valid_aggregations()
    end
  end

  describe "TeamMember.changeset/2" do
    test "validates required fields" do
      changeset = TeamMember.changeset(%TeamMember{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.team_definition_id
      assert "can't be blank" in errors.agent_definition_id
    end
  end
end
