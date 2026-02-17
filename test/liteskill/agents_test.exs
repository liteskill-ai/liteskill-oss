defmodule Liteskill.AgentsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Agents
  alias Liteskill.Agents.{AgentDefinition, AgentTool}
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

    test "preloads llm_model and agent_tools", %{owner: owner} do
      assert {:ok, agent} = Agents.create_agent(agent_attrs(owner))
      assert agent.llm_model == nil
      assert agent.agent_tools == []
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
      assert updated.agent_tools == []
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, agent} = Agents.create_agent(agent_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Agents.update_agent(agent.id, owner.id, %{strategy: "invalid"})
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

  describe "add_tool/4 and remove_tool/4 and list_tools/1" do
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

    test "adds a tool to an agent", %{owner: owner, agent: agent, server: server} do
      assert {:ok, tool} = Agents.add_tool(agent.id, server.id, "my_tool", owner.id)
      assert tool.agent_definition_id == agent.id
      assert tool.mcp_server_id == server.id
      assert tool.tool_name == "my_tool"
    end

    test "adds a tool without tool_name", %{owner: owner, agent: agent, server: server} do
      assert {:ok, tool} = Agents.add_tool(agent.id, server.id, nil, owner.id)
      assert tool.tool_name == nil
    end

    test "lists tools for an agent", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.add_tool(agent.id, server.id, "tool_a", owner.id)
      tools = Agents.list_tools(agent.id)
      assert length(tools) == 1
      assert hd(tools).tool_name == "tool_a"
    end

    test "removes a tool with tool_name", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.add_tool(agent.id, server.id, "removable", owner.id)
      assert {:ok, _} = Agents.remove_tool(agent.id, server.id, "removable", owner.id)
      assert Agents.list_tools(agent.id) == []
    end

    test "removes a tool without tool_name", %{owner: owner, agent: agent, server: server} do
      {:ok, _} = Agents.add_tool(agent.id, server.id, nil, owner.id)
      assert {:ok, _} = Agents.remove_tool(agent.id, server.id, nil, owner.id)
      assert Agents.list_tools(agent.id) == []
    end

    test "remove_tool returns not_found for missing tool", %{
      owner: owner,
      agent: agent,
      server: server
    } do
      assert {:error, :not_found} =
               Agents.remove_tool(agent.id, server.id, "nonexistent", owner.id)
    end

    test "add_tool returns forbidden for non-owner", %{other: other, agent: agent, server: server} do
      assert {:error, :forbidden} = Agents.add_tool(agent.id, server.id, nil, other.id)
    end

    test "remove_tool returns forbidden for non-owner", %{
      owner: owner,
      other: other,
      agent: agent,
      server: server
    } do
      {:ok, _} = Agents.add_tool(agent.id, server.id, nil, owner.id)
      assert {:error, :forbidden} = Agents.remove_tool(agent.id, server.id, nil, other.id)
    end

    test "add_tool returns not_found for missing agent", %{owner: owner, server: server} do
      assert {:error, :not_found} =
               Agents.add_tool(Ecto.UUID.generate(), server.id, nil, owner.id)
    end

    test "remove_tool returns not_found for missing agent", %{owner: owner, server: server} do
      assert {:error, :not_found} =
               Agents.remove_tool(Ecto.UUID.generate(), server.id, nil, owner.id)
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

  describe "AgentTool.changeset/2" do
    test "validates required fields" do
      changeset = AgentTool.changeset(%AgentTool{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.agent_definition_id
      assert "can't be blank" in errors.mcp_server_id
    end
  end
end
