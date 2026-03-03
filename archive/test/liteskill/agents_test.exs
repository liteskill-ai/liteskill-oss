defmodule Liteskill.AgentsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Agents
  alias Liteskill.Agents.AgentDefinition
  alias Liteskill.McpServers

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "agents-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Agent Owner",
        oidc_sub: "agents-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "agents-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "agents-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  defp agent_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Agent #{System.unique_integer([:positive])}",
        description: "Test agent",
        backstory: "A test backstory",
        system_prompt: "You are a test agent",
        strategy: "react",
        opinions: %{"key" => "value"},
        user_id: user.id
      },
      overrides
    )
  end

  describe "create_agent/1" do
    test "creates an agent with valid attrs and owner ACL", %{owner: owner} do
      attrs = agent_attrs(owner)
      assert {:ok, agent} = Agents.create_agent(attrs)

      assert agent.name == attrs.name
      assert agent.description == "Test agent"
      assert agent.backstory == "A test backstory"
      assert agent.strategy == "react"
      assert agent.opinions == %{"key" => "value"}
      assert agent.user_id == owner.id
      assert agent.status == "active"

      assert Liteskill.Authorization.owner?("agent_definition", agent.id, owner.id)
    end

    test "rejects create without user_id" do
      assert {:error, :forbidden} = Agents.create_agent(%{})
    end

    test "validates required fields", %{owner: owner} do
      assert {:error, changeset} = Agents.create_agent(%{user_id: owner.id})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
    end

    test "validates strategy inclusion", %{owner: owner} do
      attrs = agent_attrs(owner, %{strategy: "invalid"})
      assert {:error, changeset} = Agents.create_agent(attrs)
      assert "is invalid" in errors_on(changeset).strategy
    end

    test "validates status inclusion", %{owner: owner} do
      attrs = agent_attrs(owner, %{status: "bogus"})
      assert {:error, changeset} = Agents.create_agent(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "enforces unique name per user", %{owner: owner} do
      attrs = agent_attrs(owner, %{name: "Unique Agent"})
      assert {:ok, _} = Agents.create_agent(attrs)
      assert {:error, changeset} = Agents.create_agent(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "preloads llm_model on create", %{owner: owner} do
      assert {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert agent.llm_model == nil
    end

    test "accepts llm_model_id the user has access to", %{owner: owner} do
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Test Provider #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "test-key",
          provider_config: %{"region" => "us-east-1"},
          user_id: owner.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Test Model #{System.unique_integer([:positive])}",
          model_id: "us.anthropic.claude-3-5-sonnet",
          provider_id: provider.id,
          user_id: owner.id,
          instance_wide: true
        })

      attrs = agent_attrs(owner, %{llm_model_id: model.id})
      assert {:ok, agent} = Agents.create_agent(attrs)
      assert agent.llm_model_id == model.id
    end

    test "accepts empty string llm_model_id", %{owner: owner} do
      attrs = agent_attrs(owner, %{llm_model_id: ""})
      assert {:ok, _agent} = Agents.create_agent(attrs)
    end

    test "rejects llm_model_id the user cannot access", %{owner: owner, other: other} do
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Private Provider #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "test-key",
          provider_config: %{"region" => "us-east-1"},
          user_id: owner.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Private Model #{System.unique_integer([:positive])}",
          model_id: "us.anthropic.claude-3-5-sonnet",
          provider_id: provider.id,
          user_id: owner.id
        })

      attrs = agent_attrs(other, %{llm_model_id: model.id})
      assert {:error, :invalid_model} = Agents.create_agent(attrs)
    end
  end

  describe "update_agent/3" do
    test "updates agent as owner", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      assert {:ok, updated} = Agents.update_agent(agent.id, owner.id, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "returns not_found for missing agent", %{owner: owner} do
      assert {:error, :not_found} = Agents.update_agent(Ecto.UUID.generate(), owner.id, %{})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:error, :forbidden} = Agents.update_agent(agent.id, other.id, %{name: "Nope"})
    end

    test "preloads associations on update", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      {:ok, updated} = Agents.update_agent(agent.id, owner.id, %{description: "New desc"})
      assert updated.llm_model == nil
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Agents.update_agent(agent.id, owner.id, %{strategy: "invalid"})
    end

    test "rejects llm_model_id the user cannot access", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Other Provider #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "test-key",
          provider_config: %{"region" => "us-east-1"},
          user_id: other.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Other Model #{System.unique_integer([:positive])}",
          model_id: "us.anthropic.claude-3-5-sonnet",
          provider_id: provider.id,
          user_id: other.id
        })

      assert {:error, :invalid_model} =
               Agents.update_agent(agent.id, owner.id, %{llm_model_id: model.id})
    end

    test "allows update without llm_model_id", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:ok, updated} = Agents.update_agent(agent.id, owner.id, %{name: "No Model Change"})
      assert updated.name == "No Model Change"
    end
  end

  describe "delete_agent/2" do
    test "deletes agent as owner", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:ok, _} = Agents.delete_agent(agent.id, owner.id)
      assert {:error, :not_found} = Agents.get_agent(agent.id, owner.id)
    end

    test "returns not_found for missing agent", %{owner: owner} do
      assert {:error, :not_found} = Agents.delete_agent(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:error, :forbidden} = Agents.delete_agent(agent.id, other.id)
    end
  end

  describe "list_agents/1" do
    test "lists user's own agents", %{owner: owner} do
      {:ok, a1} = Agents.create_agent(agent_attrs(owner, %{name: "Alpha"}))
      {:ok, a2} = Agents.create_agent(agent_attrs(owner, %{name: "Beta"}))

      agents = Agents.list_agents(owner.id)
      ids = Enum.map(agents, & &1.id)
      assert a1.id in ids
      assert a2.id in ids
    end

    test "returns empty for user with no agents", %{other: other} do
      assert Agents.list_agents(other.id) == []
    end

    test "includes agents shared via ACL", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      Liteskill.Authorization.grant_access(
        "agent_definition",
        agent.id,
        owner.id,
        other.id,
        "viewer"
      )

      agents = Agents.list_agents(other.id)
      assert length(agents) == 1
      assert hd(agents).id == agent.id
    end
  end

  describe "get_agent/2" do
    test "returns agent for owner", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:ok, found} = Agents.get_agent(agent.id, owner.id)
      assert found.id == agent.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Agents.get_agent(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert {:error, :not_found} = Agents.get_agent(agent.id, other.id)
    end

    test "returns agent for user with ACL", %{owner: owner, other: other} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      Liteskill.Authorization.grant_access(
        "agent_definition",
        agent.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Agents.get_agent(agent.id, other.id)
      assert found.id == agent.id
    end
  end

  describe "get_agent!/1" do
    test "returns agent without auth check", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      found = Agents.get_agent!(agent.id)
      assert found.id == agent.id
    end
  end

  describe "grant_tool_access/3 and revoke_tool_access/3" do
    setup %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      {:ok, server} =
        McpServers.create_server(%{
          name: "Test MCP #{System.unique_integer([:positive])}",
          url: "https://mcp-test.example.com",
          user_id: owner.id
        })

      %{agent: agent, server: server}
    end

    test "grants tool access to an agent", %{owner: owner, agent: agent, server: server} do
      assert {:ok, acl} = Agents.grant_tool_access(agent.id, server.id, owner.id)
      assert acl.entity_type == "mcp_server"
      assert acl.entity_id == server.id
      assert acl.agent_definition_id == agent.id
      assert acl.role == "viewer"
    end

    test "lists tool server IDs", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.grant_tool_access(agent.id, server.id, owner.id)
      ids = Agents.list_tool_server_ids(agent.id)
      assert server.id in ids
    end

    test "lists accessible servers", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.grant_tool_access(agent.id, server.id, owner.id)
      servers = Agents.list_accessible_servers(agent.id)
      assert length(servers) == 1
      assert hd(servers).id == server.id
    end

    test "revokes tool access", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.grant_tool_access(agent.id, server.id, owner.id)
      assert {:ok, _} = Agents.revoke_tool_access(agent.id, server.id, owner.id)
      assert Agents.list_tool_server_ids(agent.id) == []
    end

    test "revoke_tool_access returns not_found when no access exists", %{
      owner: owner,
      agent: agent,
      server: server
    } do
      assert {:error, :not_found} = Agents.revoke_tool_access(agent.id, server.id, owner.id)
    end

    test "grant_tool_access returns forbidden for non-owner", %{
      other: other,
      agent: agent,
      server: server
    } do
      assert {:error, :forbidden} = Agents.grant_tool_access(agent.id, server.id, other.id)
    end

    test "revoke_tool_access returns forbidden for non-owner", %{
      owner: owner,
      other: other,
      agent: agent,
      server: server
    } do
      {:ok, _} = Agents.grant_tool_access(agent.id, server.id, owner.id)
      assert {:error, :forbidden} = Agents.revoke_tool_access(agent.id, server.id, other.id)
    end

    test "grant_tool_access returns not_found for missing agent", %{owner: owner, server: server} do
      assert {:error, :not_found} =
               Agents.grant_tool_access(Ecto.UUID.generate(), server.id, owner.id)
    end

    test "revoke_tool_access returns not_found for missing agent", %{
      owner: owner,
      server: server
    } do
      assert {:error, :not_found} =
               Agents.revoke_tool_access(Ecto.UUID.generate(), server.id, owner.id)
    end
  end

  describe "grant_source_access/3 and revoke_source_access/3" do
    setup %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      {:ok, source} =
        Liteskill.DataSources.create_source(
          %{
            name: "Test Source #{System.unique_integer([:positive])}",
            source_type: "google_drive"
          },
          owner.id
        )

      %{agent: agent, source: source}
    end

    test "grants source access to an agent", %{owner: owner, agent: agent, source: source} do
      assert {:ok, acl} = Agents.grant_source_access(agent.id, source.id, owner.id)
      assert acl.entity_type == "source"
      assert acl.entity_id == source.id
      assert acl.agent_definition_id == agent.id
    end

    test "lists source IDs", %{owner: owner, agent: agent, source: source} do
      {:ok, _} = Agents.grant_source_access(agent.id, source.id, owner.id)
      ids = Agents.list_source_ids(agent.id)
      assert source.id in ids
    end

    test "revokes source access", %{owner: owner, agent: agent, source: source} do
      {:ok, _} = Agents.grant_source_access(agent.id, source.id, owner.id)
      assert {:ok, _} = Agents.revoke_source_access(agent.id, source.id, owner.id)
      assert Agents.list_source_ids(agent.id) == []
    end

    test "grant_source_access returns forbidden for non-owner", %{
      other: other,
      agent: agent,
      source: source
    } do
      assert {:error, :forbidden} = Agents.grant_source_access(agent.id, source.id, other.id)
    end

    test "revoke_source_access returns not_found when no access exists", %{
      owner: owner,
      agent: agent,
      source: source
    } do
      assert {:error, :not_found} = Agents.revoke_source_access(agent.id, source.id, owner.id)
    end
  end

  describe "AgentDefinition.changeset/2" do
    test "accepts all valid strategies" do
      for strategy <- AgentDefinition.valid_strategies() do
        changeset =
          AgentDefinition.changeset(%AgentDefinition{}, %{
            name: "test",
            user_id: Ecto.UUID.generate(),
            strategy: strategy
          })

        assert changeset.valid?
      end
    end
  end

  describe "role assignment via create/update" do
    setup %{owner: owner} do
      Liteskill.Rbac.ensure_system_roles()

      {:ok, role} =
        Liteskill.Rbac.create_role(%{
          name: "Agent Test Role-#{System.unique_integer([:positive])}"
        })

      %{owner: owner, role: role}
    end

    test "create_agent assigns role when role_id provided", %{owner: owner, role: role} do
      attrs = agent_attrs(owner, %{role_id: role.id})
      assert {:ok, agent} = Agents.create_agent(attrs)

      roles = Liteskill.Rbac.list_agent_roles(agent.id)
      assert Enum.any?(roles, &(&1.id == role.id))
    end

    test "create_agent without role_id assigns no role", %{owner: owner} do
      assert {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert Liteskill.Rbac.list_agent_roles(agent.id) == []
    end

    test "update_agent changes role", %{owner: owner, role: role} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner, %{role_id: role.id}))

      {:ok, role2} =
        Liteskill.Rbac.create_role(%{
          name: "Agent Role 2-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Agents.update_agent(agent.id, owner.id, %{"role_id" => role2.id})

      roles = Liteskill.Rbac.list_agent_roles(agent.id)
      assert length(roles) == 1
      assert hd(roles).id == role2.id
    end

    test "update_agent removes role when role_id is empty", %{owner: owner, role: role} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner, %{role_id: role.id}))
      {:ok, _} = Agents.update_agent(agent.id, owner.id, %{"role_id" => ""})

      assert Liteskill.Rbac.list_agent_roles(agent.id) == []
    end
  end
end
