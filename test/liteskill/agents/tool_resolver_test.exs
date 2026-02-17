defmodule Liteskill.Agents.ToolResolverTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Agents
  alias Liteskill.Agents.ToolResolver

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "resolver-#{System.unique_integer([:positive])}@example.com",
        name: "Resolver Owner",
        oidc_sub: "resolver-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Resolver Agent #{System.unique_integer([:positive])}",
        strategy: "direct",
        user_id: owner.id
      })

    %{owner: owner, agent: agent}
  end

  describe "resolve/2 — no tools" do
    test "returns empty when agent has no tools or builtins", %{agent: agent, owner: owner} do
      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools == []
      assert servers == %{}
    end
  end

  describe "resolve/2 — builtin tools" do
    test "resolves builtin tools from config", %{owner: owner} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Builtin Agent #{System.unique_integer([:positive])}",
          strategy: "direct",
          config: %{"builtin_server_ids" => ["builtin:reports"]},
          user_id: owner.id
        })

      {:ok, agent} = Agents.get_agent(agent.id, owner.id)

      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools != []

      tool_names = Enum.map(tools, &get_in(&1, ["toolSpec", "name"]))
      assert Enum.any?(tool_names, &String.starts_with?(&1, "reports__"))

      # All builtin tools have correct spec shape
      Enum.each(tools, fn tool ->
        assert Map.has_key?(tool, "toolSpec")
        spec = tool["toolSpec"]
        assert is_binary(spec["name"])
        assert is_binary(spec["description"])
        assert is_map(spec["inputSchema"])
        assert is_map(spec["inputSchema"]["json"])
      end)

      # All builtin tools map to a server with :builtin key
      Enum.each(tool_names, fn name ->
        server = Map.get(servers, name)
        assert server != nil, "Expected server for tool #{name}"
        assert Map.has_key?(server, :builtin)
        assert Map.has_key?(server, :id)
        assert Map.has_key?(server, :name)
      end)
    end

    test "ignores unknown builtin IDs", %{owner: owner} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unknown Builtin #{System.unique_integer([:positive])}",
          strategy: "direct",
          config: %{"builtin_server_ids" => ["builtin:nonexistent"]},
          user_id: owner.id
        })

      {:ok, agent} = Agents.get_agent(agent.id, owner.id)

      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools == []
      assert servers == %{}
    end

    test "resolves multiple builtin IDs including unknown ones", %{owner: owner} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Mixed Builtin #{System.unique_integer([:positive])}",
          strategy: "direct",
          config: %{"builtin_server_ids" => ["builtin:reports", "builtin:nonexistent"]},
          user_id: owner.id
        })

      {:ok, agent} = Agents.get_agent(agent.id, owner.id)

      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      # Only reports tools should be resolved, nonexistent is skipped
      assert tools != []

      tool_names = Enum.map(tools, &get_in(&1, ["toolSpec", "name"]))
      assert Enum.all?(tool_names, &String.starts_with?(&1, "reports__"))
      assert map_size(servers) == length(tools)
    end

    test "returns empty when no builtin_server_ids in config", %{agent: agent, owner: owner} do
      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools == []
      assert servers == %{}
    end

    test "handles nil config gracefully", %{owner: owner} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Nil Config #{System.unique_integer([:positive])}",
          strategy: "direct",
          config: %{},
          user_id: owner.id
        })

      {:ok, agent} = Agents.get_agent(agent.id, owner.id)

      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools == []
      assert servers == %{}
    end
  end

  describe "resolve/2 — MCP tools with unreachable server" do
    test "handles unreachable MCP server gracefully", %{owner: owner, agent: agent} do
      {:ok, server} =
        Liteskill.McpServers.create_server(%{
          name: "Unreachable MCP #{System.unique_integer([:positive])}",
          url: "https://unreachable.invalid.test",
          user_id: owner.id
        })

      {:ok, _tool} = Agents.add_tool(agent.id, server.id, nil, owner.id)
      {:ok, agent} = Agents.get_agent(agent.id, owner.id)

      # Should return empty results, not crash
      {tools, servers} =
        ToolResolver.resolve(agent, owner.id, builtin_registry: Liteskill.BuiltinTools)

      assert tools == []
      assert servers == %{}
    end
  end
end
