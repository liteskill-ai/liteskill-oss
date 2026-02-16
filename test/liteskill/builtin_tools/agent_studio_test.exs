defmodule Liteskill.BuiltinTools.AgentStudioTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.BuiltinTools.AgentStudio, as: AgentStudioTool

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "studio-user-#{System.unique_integer([:positive])}@example.com",
        name: "Studio User",
        oidc_sub: "studio-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, provider} =
      Liteskill.LlmProviders.create_provider(%{
        name: "Test Provider #{System.unique_integer([:positive])}",
        provider_type: "anthropic",
        api_key: "test-key",
        user_id: user.id
      })

    {:ok, model} =
      Liteskill.LlmModels.create_model(%{
        name: "Test Model #{System.unique_integer([:positive])}",
        model_id: "claude-test-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        user_id: user.id
      })

    {:ok, server} =
      Liteskill.McpServers.create_server(%{
        name: "Test MCP #{System.unique_integer([:positive])}",
        url: "https://mcp-test.example.com",
        user_id: user.id
      })

    %{user: user, model: model, server: server}
  end

  # --- Metadata ---

  test "id/0 returns agent_studio" do
    assert AgentStudioTool.id() == "agent_studio"
  end

  test "name/0 returns Agent Studio" do
    assert AgentStudioTool.name() == "Agent Studio"
  end

  test "description/0 returns a string" do
    assert is_binary(AgentStudioTool.description())
  end

  test "list_tools/0 returns 17 tool definitions" do
    tools = AgentStudioTool.list_tools()
    assert length(tools) == 17

    names = Enum.map(tools, & &1["name"])
    assert "agent_studio__list_models" in names
    assert "agent_studio__list_available_tools" in names
    assert "agent_studio__create_agent" in names
    assert "agent_studio__list_agents" in names
    assert "agent_studio__get_agent" in names
    assert "agent_studio__delete_agent" in names
    assert "agent_studio__create_team" in names
    assert "agent_studio__list_teams" in names
    assert "agent_studio__get_team" in names
    assert "agent_studio__delete_team" in names
    assert "agent_studio__start_run" in names
    assert "agent_studio__list_runs" in names
    assert "agent_studio__get_run" in names
    assert "agent_studio__cancel_run" in names
    assert "agent_studio__create_schedule" in names
    assert "agent_studio__list_schedules" in names
    assert "agent_studio__delete_schedule" in names
  end

  describe "discovery tools" do
    test "list_models returns available models", %{user: user, model: model} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__list_models", %{}, ctx)
      data = decode_content(result)
      model_ids = Enum.map(data["models"], & &1["id"])
      assert model.id in model_ids
    end

    test "list_available_tools returns servers", %{user: user, server: server} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool("agent_studio__list_available_tools", %{}, ctx)

      data = decode_content(result)
      server_ids = Enum.map(data["servers"], & &1["id"])
      assert server.id in server_ids
      # Should also include builtin servers
      assert Enum.any?(data["servers"], & &1["builtin"])
    end
  end

  describe "agent tools" do
    test "create, list, get, delete flow", %{user: user, model: model, server: server} do
      ctx = [user_id: user.id]

      # Create with inline tools
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{
                   "name" => "Research Agent #{System.unique_integer([:positive])}",
                   "description" => "Researches topics",
                   "system_prompt" => "You are a researcher",
                   "strategy" => "react",
                   "llm_model_id" => model.id,
                   "tools" => [%{"server_id" => server.id, "tool_name" => "search"}]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["name"] =~ "Research Agent"
      agent_id = data["id"]
      assert length(data["tools_assigned"]) == 1
      assert hd(data["tools_assigned"])["status"] == "ok"

      # List
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__list_agents", %{}, ctx)
      data = decode_content(result)
      ids = Enum.map(data["agents"], & &1["id"])
      assert agent_id in ids

      # Get
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_agent",
                 %{"agent_id" => agent_id},
                 ctx
               )

      data = decode_content(result)
      assert data["id"] == agent_id
      assert data["strategy"] == "react"
      assert data["model"]["id"] == model.id
      assert length(data["tools"]) == 1

      # Delete
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_agent",
                 %{"agent_id" => agent_id},
                 ctx
               )

      assert decode_content(result)["deleted"] == true
    end

    test "create agent without tools", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{"name" => "Simple Agent #{System.unique_integer([:positive])}"},
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert data["tools_assigned"] == []
    end

    test "create agent with builtin_server_ids", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{
                   "name" => "Builtin Agent #{System.unique_integer([:positive])}",
                   "builtin_server_ids" => ["builtin:reports"]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["id"]

      # Verify config has the builtin_server_ids
      {:ok, agent} = Liteskill.Agents.get_agent(data["id"], user.id)
      assert agent.config["builtin_server_ids"] == ["builtin:reports"]
    end

    test "create agent missing name returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__create_agent", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "get non-existent agent returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_agent",
                 %{"agent_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "delete non-existent agent returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_agent",
                 %{"agent_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "get agent missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__get_agent", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "delete agent missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__delete_agent", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end
  end

  describe "team tools" do
    test "create, list, get, delete flow", %{user: user} do
      ctx = [user_id: user.id]

      # Create an agent first for the team
      {:ok, agent_result} =
        AgentStudioTool.call_tool(
          "agent_studio__create_agent",
          %{"name" => "Team Agent #{System.unique_integer([:positive])}"},
          ctx
        )

      agent_id = decode_content(agent_result)["id"]

      # Create team with inline members
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_team",
                 %{
                   "name" => "Research Team #{System.unique_integer([:positive])}",
                   "description" => "Research pipeline",
                   "topology" => "pipeline",
                   "members" => [
                     %{"agent_id" => agent_id, "role" => "lead", "description" => "Lead agent"}
                   ]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["name"] =~ "Research Team"
      team_id = data["id"]
      assert length(data["members_assigned"]) == 1
      assert hd(data["members_assigned"])["status"] == "ok"

      # List
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__list_teams", %{}, ctx)
      data = decode_content(result)
      ids = Enum.map(data["teams"], & &1["id"])
      assert team_id in ids

      # Get
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_team",
                 %{"team_id" => team_id},
                 ctx
               )

      data = decode_content(result)
      assert data["id"] == team_id
      assert data["topology"] == "pipeline"
      assert length(data["members"]) == 1
      assert hd(data["members"])["role"] == "lead"

      # Delete
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_team",
                 %{"team_id" => team_id},
                 ctx
               )

      assert decode_content(result)["deleted"] == true
    end

    test "create team without members", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_team",
                 %{"name" => "Empty Team #{System.unique_integer([:positive])}"},
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert data["members_assigned"] == []
    end

    test "create team with duplicate name returns error", %{user: user} do
      ctx = [user_id: user.id]
      name = "Dup Team #{System.unique_integer([:positive])}"

      {:ok, _} =
        AgentStudioTool.call_tool("agent_studio__create_team", %{"name" => name}, ctx)

      {:ok, result} =
        AgentStudioTool.call_tool("agent_studio__create_team", %{"name" => name}, ctx)

      assert decode_content(result)["error"] =~ "Validation failed"
    end

    test "create team missing name returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__create_team", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "get non-existent team returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_team",
                 %{"team_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "delete non-existent team returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_team",
                 %{"team_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "get team missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__get_team", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "delete team missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__delete_team", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end
  end

  describe "run tools" do
    test "start, list, get flow", %{user: user} do
      ctx = [user_id: user.id]

      # Start a run (without a team — it will likely fail quickly but that's ok)
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__start_run",
                 %{"prompt" => "Test prompt", "name" => "Test Run"},
                 ctx
               )

      data = decode_content(result)
      run_id = data["id"]
      assert data["status"] == "pending"
      assert data["message"] =~ "poll"

      # Allow the async task to start
      Process.sleep(50)

      # List
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__list_runs", %{}, ctx)
      data = decode_content(result)
      ids = Enum.map(data["runs"], & &1["id"])
      assert run_id in ids

      # Get
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_run",
                 %{"run_id" => run_id},
                 ctx
               )

      data = decode_content(result)
      assert data["id"] == run_id
      assert data["prompt"] == "Test prompt"
    end

    test "cancel a running run succeeds", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Running Run",
          prompt: "Test",
          user_id: user.id
        })

      {:ok, _} =
        Liteskill.Runs.update_run(run.id, user.id, %{
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__cancel_run",
                 %{"run_id" => run.id},
                 ctx
               )

      data = decode_content(result)
      assert data["id"] == run.id
      assert data["status"] == "cancelled"
    end

    test "get run with tasks shows task details", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Task Run",
          prompt: "Test",
          user_id: user.id
        })

      {:ok, _task} =
        Liteskill.Runs.add_task(run.id, %{
          name: "Step 1",
          status: "completed",
          duration_ms: 1234
        })

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_run",
                 %{"run_id" => run.id},
                 ctx
               )

      data = decode_content(result)
      assert length(data["tasks"]) == 1
      task = hd(data["tasks"])
      assert task["name"] == "Step 1"
      assert task["status"] == "completed"
      assert task["duration_ms"] == 1234
    end

    test "cancel a non-running run returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Pending Run",
          prompt: "Test",
          user_id: user.id
        })

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__cancel_run",
                 %{"run_id" => run.id},
                 ctx
               )

      assert decode_content(result)["error"] == "not_running"
    end

    test "start run with invalid topology returns validation error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        AgentStudioTool.call_tool(
          "agent_studio__start_run",
          %{"prompt" => "Test", "topology" => "invalid_topology"},
          ctx
        )

      assert decode_content(result)["error"] =~ "Validation failed"
    end

    test "start run missing prompt returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__start_run", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "get non-existent run returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__get_run",
                 %{"run_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "cancel non-existent run returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__cancel_run",
                 %{"run_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "get run missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__get_run", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "cancel run missing field returns error", %{user: user} do
      ctx = [user_id: user.id]
      assert {:ok, result} = AgentStudioTool.call_tool("agent_studio__cancel_run", %{}, ctx)
      assert decode_content(result)["error"] =~ "Missing required field"
    end
  end

  describe "schedule tools" do
    test "create, list, delete flow", %{user: user} do
      ctx = [user_id: user.id]

      # Create
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_schedule",
                 %{
                   "name" => "Morning Run #{System.unique_integer([:positive])}",
                   "cron_expression" => "0 9 * * 1-5",
                   "timezone" => "UTC",
                   "prompt" => "Daily research",
                   "enabled" => true
                 },
                 ctx
               )

      data = decode_content(result)
      schedule_id = data["id"]
      assert data["cron_expression"] == "0 9 * * 1-5"
      assert data["enabled"] == true
      assert data["next_run_at"]

      # List
      assert {:ok, result} =
               AgentStudioTool.call_tool("agent_studio__list_schedules", %{}, ctx)

      data = decode_content(result)
      ids = Enum.map(data["schedules"], & &1["id"])
      assert schedule_id in ids

      # Delete
      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_schedule",
                 %{"schedule_id" => schedule_id},
                 ctx
               )

      assert decode_content(result)["deleted"] == true
    end

    test "create schedule with duplicate name returns error", %{user: user} do
      ctx = [user_id: user.id]
      name = "Dup Schedule #{System.unique_integer([:positive])}"

      {:ok, _} =
        AgentStudioTool.call_tool(
          "agent_studio__create_schedule",
          %{"name" => name, "cron_expression" => "0 9 * * *", "prompt" => "test"},
          ctx
        )

      {:ok, result} =
        AgentStudioTool.call_tool(
          "agent_studio__create_schedule",
          %{"name" => name, "cron_expression" => "0 10 * * *", "prompt" => "test2"},
          ctx
        )

      assert decode_content(result)["error"] =~ "Validation failed"
    end

    test "create schedule missing cron_expression returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool("agent_studio__create_schedule", %{}, ctx)

      assert decode_content(result)["error"] =~ "Missing required field"
    end

    test "delete non-existent schedule returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__delete_schedule",
                 %{"schedule_id" => Ecto.UUID.generate()},
                 ctx
               )

      assert decode_content(result)["error"] == "not_found"
    end

    test "delete schedule missing field returns error", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool("agent_studio__delete_schedule", %{}, ctx)

      assert decode_content(result)["error"] =~ "Missing required field"
    end
  end

  describe "error handling" do
    test "unknown tool returns error", %{user: user} do
      {:ok, result} = AgentStudioTool.call_tool("agent_studio__unknown", %{}, user_id: user.id)
      data = decode_content(result)
      assert data["error"] =~ "Unknown tool"
    end

    test "create agent with duplicate name returns error", %{user: user} do
      ctx = [user_id: user.id]
      name = "Duplicate Agent #{System.unique_integer([:positive])}"

      {:ok, _} =
        AgentStudioTool.call_tool("agent_studio__create_agent", %{"name" => name}, ctx)

      {:ok, result} =
        AgentStudioTool.call_tool("agent_studio__create_agent", %{"name" => name}, ctx)

      assert decode_content(result)["error"] =~ "Validation failed"
    end

    test "create team with failed member assignment", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_team",
                 %{
                   "name" => "Bad Members Team #{System.unique_integer([:positive])}",
                   "members" => [%{"agent_id" => Ecto.UUID.generate()}]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert hd(data["members_assigned"])["status"] == "failed"
    end

    test "create agent with builtin tools in tools array", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{
                   "name" => "Wiki Agent #{System.unique_integer([:positive])}",
                   "tools" => [
                     %{"server_id" => "builtin:wiki"},
                     %{"server_id" => "builtin:reports"}
                   ]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert length(data["tools_assigned"]) == 2
      assert Enum.all?(data["tools_assigned"], &(&1["status"] == "ok"))

      # Verify builtin IDs ended up in config, not as AgentTool records
      {:ok, agent} = Liteskill.Agents.get_agent(data["id"], user.id)
      assert "builtin:wiki" in agent.config["builtin_server_ids"]
      assert "builtin:reports" in agent.config["builtin_server_ids"]
      assert agent.agent_tools == []
    end

    test "create agent with mixed builtin and MCP tools", %{user: user, server: server} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{
                   "name" => "Mixed Agent #{System.unique_integer([:positive])}",
                   "tools" => [
                     %{"server_id" => "builtin:wiki"},
                     %{"server_id" => server.id, "tool_name" => "search"}
                   ]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert length(data["tools_assigned"]) == 2
      assert Enum.all?(data["tools_assigned"], &(&1["status"] == "ok"))

      {:ok, agent} = Liteskill.Agents.get_agent(data["id"], user.id)
      assert "builtin:wiki" in agent.config["builtin_server_ids"]
      assert length(agent.agent_tools) == 1
    end

    test "create agent with failed tool assignment", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               AgentStudioTool.call_tool(
                 "agent_studio__create_agent",
                 %{
                   "name" => "Bad Tools Agent #{System.unique_integer([:positive])}",
                   "tools" => [
                     %{"server_id" => Ecto.UUID.generate(), "tool_name" => "nonexistent"}
                   ]
                 },
                 ctx
               )

      data = decode_content(result)
      assert data["id"]
      assert hd(data["tools_assigned"])["status"] == "failed"
    end
  end

  defp decode_content(%{"content" => [%{"text" => json}]}) do
    Jason.decode!(json)
  end
end
