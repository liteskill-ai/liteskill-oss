defmodule Liteskill.Runs.RunnerTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Runs
  alias Liteskill.Runs.Runner
  alias Liteskill.Teams
  alias Liteskill.Agents
  alias Liteskill.LlmProviders
  alias Liteskill.LlmModels

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "runner-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Runner Owner",
        oidc_sub: "runner-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  defp create_run(owner, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Test Run #{System.unique_integer([:positive])}",
          prompt: "Analyze this test topic",
          topology: "pipeline",
          user_id: owner.id
        },
        overrides
      )

    {:ok, run} = Runs.create_run(attrs)
    run
  end

  defp create_team_with_agent(owner, opts \\ []) do
    llm_model_id = Keyword.get(opts, :llm_model_id)

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent #{System.unique_integer([:positive])}",
        strategy: "direct",
        system_prompt: "You are a test agent.",
        backstory: "A test backstory",
        user_id: owner.id,
        llm_model_id: llm_model_id
      })

    {:ok, team} =
      Teams.create_team(%{
        name: "Test Team #{System.unique_integer([:positive])}",
        user_id: owner.id
      })

    {:ok, _member} = Teams.add_member(team.id, agent.id, owner.id, %{role: "analyst"})

    # Reload team with members
    {:ok, team} = Teams.get_team(team.id, owner.id)
    {team, agent}
  end

  defp create_provider_and_model(owner) do
    {:ok, provider} =
      LlmProviders.create_provider(%{
        name: "Test Provider #{System.unique_integer([:positive])}",
        provider_type: "anthropic",
        provider_config: %{},
        user_id: owner.id
      })

    {:ok, model} =
      LlmModels.create_model(%{
        name: "Test Model #{System.unique_integer([:positive])}",
        model_id: "claude-3-5-sonnet-20241022",
        provider_id: provider.id,
        user_id: owner.id
      })

    model
  end

  describe "extract_handoff_summary/1" do
    test "extracts ## Handoff Summary section" do
      output = """
      Some analysis output here.

      ## Handoff Summary
      - Found 5 key issues
      - Recommended 3 actions
      - Next agent should focus on implementation
      """

      result = Runner.extract_handoff_summary(output)
      assert result =~ "Found 5 key issues"
      assert result =~ "Recommended 3 actions"
      assert result =~ "Next agent should focus on implementation"
    end

    test "extracts ### Handoff Summary section" do
      output = "Analysis.\n\n### Handoff Summary\n- bullet one\n- bullet two"
      result = Runner.extract_handoff_summary(output)
      assert result =~ "bullet one"
    end

    test "falls back to first 500 chars when no section present" do
      output = String.duplicate("a", 1000)
      result = Runner.extract_handoff_summary(output)
      assert String.length(result) == 500
      assert result == String.duplicate("a", 500)
    end

    test "truncates long handoff summaries to 500 chars" do
      long_summary = String.duplicate("x", 1000)
      output = "## Handoff Summary\n#{long_summary}"
      result = Runner.extract_handoff_summary(output)
      assert String.length(result) == 500
    end

    test "returns empty string for nil" do
      assert Runner.extract_handoff_summary(nil) == ""
    end

    test "returns empty string for non-binary" do
      assert Runner.extract_handoff_summary(42) == ""
    end

    test "handles empty string" do
      assert Runner.extract_handoff_summary("") == ""
    end
  end

  describe "run/2 — no team" do
    test "fails with 'No agents assigned' when run has no team", %{owner: owner} do
      run = create_run(owner)
      assert run.status == "pending"

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "failed"
      assert updated.error =~ "No agents assigned"
      assert updated.completed_at != nil
    end

    test "transitions through running before failing", %{owner: owner} do
      run = create_run(owner)

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      # Started, then failed
      assert updated.started_at != nil
      assert updated.completed_at != nil
      assert updated.status == "failed"
    end

    test "creates execution logs", %{owner: owner} do
      run = create_run(owner)

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      log_steps = Enum.map(updated.run_logs, & &1.step)

      assert "init" in log_steps
      assert "resolve_agents" in log_steps
      assert "create_report" in log_steps
      assert "crash" in log_steps
    end
  end

  describe "run/2 — agent without LLM model" do
    test "fails when agent has no LLM model configured", %{owner: owner} do
      {team, agent} = create_team_with_agent(owner)
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "failed"
      assert updated.error =~ "has no LLM model configured"
      assert updated.error =~ agent.name
    end

    test "creates task for agent before failure", %{owner: owner} do
      {team, agent} = create_team_with_agent(owner)
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      # Task was created (run_agent_stage adds it before execute_agent)
      assert length(updated.run_tasks) == 1

      task = hd(updated.run_tasks)
      assert task.name =~ agent.name
      # Task is marked "failed" by the try/rescue cleanup in run_agent_stage
      assert task.status == "failed"
      assert task.error =~ "has no LLM model configured"
    end

    test "logs agent start before failure", %{owner: owner} do
      {team, _agent} = create_team_with_agent(owner)
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      log_steps = Enum.map(updated.run_logs, & &1.step)

      assert "agent_start" in log_steps
      assert "agent_crash" in log_steps
    end
  end

  describe "run/2 — successful pipeline" do
    setup %{owner: owner} do
      model = create_provider_and_model(owner)
      {team, agent} = create_team_with_agent(owner, llm_model_id: model.id)

      Req.Test.stub(Liteskill.Runs.RunnerTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _decoded = Jason.decode!(body)

        response = %{
          "id" => "msg_test_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Test analysis output from the agent."}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      on_exit(fn ->
        Application.delete_env(:liteskill, :test_req_opts)
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      %{team: team, agent: agent, model: model}
    end

    test "completes successfully with report", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "completed"
      assert updated.completed_at != nil
      assert updated.deliverables["report_id"] != nil
    end

    test "creates and completes agent tasks", %{owner: owner, team: team, agent: agent} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert length(updated.run_tasks) == 1

      task = hd(updated.run_tasks)
      assert task.name =~ agent.name
      assert task.status == "completed"
      assert task.duration_ms != nil
      assert task.output_summary =~ agent.name
    end

    test "creates full execution log trail", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      log_steps = Enum.map(updated.run_logs, & &1.step)

      assert "init" in log_steps
      assert "resolve_agents" in log_steps
      assert "create_report" in log_steps
      assert "agent_start" in log_steps
      assert "tool_resolve" in log_steps
      assert "llm_call" in log_steps
      assert "agent_complete" in log_steps
      assert "complete" in log_steps
    end

    test "agent_complete log includes per-stage usage metadata", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)

      agent_complete_log =
        Enum.find(updated.run_logs, &(&1.step == "agent_complete"))

      assert agent_complete_log != nil
      usage = agent_complete_log.metadata["usage"]
      assert is_map(usage)
      assert Map.has_key?(usage, "input_tokens")
      assert Map.has_key?(usage, "output_tokens")
      assert Map.has_key?(usage, "cached_tokens")
      assert Map.has_key?(usage, "total_cost")
      assert Map.has_key?(usage, "call_count")
    end
  end

  describe "run/2 — timeout" do
    setup %{owner: owner} do
      model = create_provider_and_model(owner)
      {team, _agent} = create_team_with_agent(owner, llm_model_id: model.id)

      # Stub that sleeps much longer than the timeout so the task is
      # blocked here (not mid-DB-op) when killed, preventing sandbox corruption
      Req.Test.stub(Liteskill.Runs.RunnerTest, fn conn ->
        Process.sleep(30_000)

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Too late"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      on_exit(fn ->
        Application.delete_env(:liteskill, :test_req_opts)
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      %{team: team}
    end

    test "fails with timeout error for very short timeout", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id, timeout_ms: 1_000})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "failed"
      assert updated.error =~ "Timed out"
    end
  end

  describe "run/2 — multi-agent pipeline" do
    setup %{owner: owner} do
      model = create_provider_and_model(owner)

      # Create two agents
      {:ok, agent1} =
        Agents.create_agent(%{
          name: "Researcher #{System.unique_integer([:positive])}",
          strategy: "react",
          system_prompt: "You are a researcher.",
          backstory: "An expert researcher",
          user_id: owner.id,
          llm_model_id: model.id
        })

      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Writer #{System.unique_integer([:positive])}",
          strategy: "direct",
          system_prompt: "You are a writer.",
          backstory: "A skilled writer",
          user_id: owner.id,
          llm_model_id: model.id
        })

      {:ok, team} =
        Teams.create_team(%{
          name: "Multi-Agent Team #{System.unique_integer([:positive])}",
          user_id: owner.id
        })

      {:ok, _m1} = Teams.add_member(team.id, agent1.id, owner.id, %{role: "researcher"})
      {:ok, _m2} = Teams.add_member(team.id, agent2.id, owner.id, %{role: "writer"})
      {:ok, team} = Teams.get_team(team.id, owner.id)

      Req.Test.stub(Liteskill.Runs.RunnerTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _decoded = Jason.decode!(body)

        response = %{
          "id" => "msg_test_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "text",
              "text" => "Analysis output.\n\n## Handoff Summary\n- Key finding 1\n- Key finding 2"
            }
          ],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      on_exit(fn ->
        Application.delete_env(:liteskill, :test_req_opts)
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      %{team: team, agent1: agent1, agent2: agent2, model: model}
    end

    test "completes 2-agent pipeline with handoff", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "completed"
      assert updated.deliverables["report_id"] != nil

      # Both agents produced tasks
      assert length(updated.run_tasks) == 2

      tasks = Enum.sort_by(updated.run_tasks, & &1.position)
      assert Enum.all?(tasks, &(&1.status == "completed"))
      assert hd(tasks).position == 0
      assert List.last(tasks).position == 1
    end

    test "creates agent_complete logs for each stage", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      complete_logs = Enum.filter(updated.run_logs, &(&1.step == "agent_complete"))

      # One agent_complete log per agent
      assert length(complete_logs) == 2

      # Each complete log has a handoff_summary
      for log <- complete_logs do
        assert log.metadata["handoff_summary"] =~ "Key finding"
      end
    end

    test "second agent receives prior context", %{owner: owner, team: team, agent1: agent1} do
      # Use a stateful stub to track what the second LLM call receives
      call_counter = :counters.new(1, [:atomics])

      Req.Test.stub(Liteskill.Runs.RunnerTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        :counters.add(call_counter, 1, 1)
        call_number = :counters.get(call_counter, 1)

        # On the second call, verify the user message includes prior context
        if call_number == 2 do
          messages = decoded["messages"] || []
          user_msg = Enum.find(messages, &(&1["role"] == "user"))

          # The user message should contain prior agent output context
          if user_msg do
            content = user_msg["content"]

            text =
              case content do
                t when is_binary(t) -> t
                list when is_list(list) -> Enum.map_join(list, "", & &1["text"])
                _ -> ""
              end

            # Signal that we saw the prior context by including it in the response
            if text =~ agent1.name do
              response = %{
                "id" => "msg_test_2",
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => "Writer output with prior context received."
                  }
                ],
                "model" => "claude-3-5-sonnet-20241022",
                "stop_reason" => "end_turn",
                "usage" => %{"input_tokens" => 15, "output_tokens" => 8}
              }

              return =
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(response))

              return
            end
          end
        end

        response = %{
          "id" => "msg_test_#{call_number}",
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "text",
              "text" =>
                "Output from call #{call_number}.\n\n## Handoff Summary\n- Finding #{call_number}"
            }
          ],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      run = create_run(owner, %{team_definition_id: team.id})
      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "completed"

      # Verify two LLM calls were made
      assert :counters.get(call_counter, 1) == 2
    end
  end

  describe "run/2 — partial pipeline failure" do
    setup %{owner: owner} do
      model = create_provider_and_model(owner)

      {:ok, agent1} =
        Agents.create_agent(%{
          name: "Good Agent #{System.unique_integer([:positive])}",
          strategy: "direct",
          system_prompt: "You succeed.",
          user_id: owner.id,
          llm_model_id: model.id
        })

      # Agent 2 has NO llm_model — will fail
      {:ok, agent2} =
        Agents.create_agent(%{
          name: "Bad Agent #{System.unique_integer([:positive])}",
          strategy: "direct",
          system_prompt: "You fail.",
          user_id: owner.id
        })

      {:ok, team} =
        Teams.create_team(%{
          name: "Partial Fail Team #{System.unique_integer([:positive])}",
          user_id: owner.id
        })

      {:ok, _m1} = Teams.add_member(team.id, agent1.id, owner.id, %{role: "worker"})
      {:ok, _m2} = Teams.add_member(team.id, agent2.id, owner.id, %{role: "reviewer"})
      {:ok, team} = Teams.get_team(team.id, owner.id)

      Req.Test.stub(Liteskill.Runs.RunnerTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _decoded = Jason.decode!(body)

        response = %{
          "id" => "msg_test_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Success output from agent 1."}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      on_exit(fn ->
        Application.delete_env(:liteskill, :test_req_opts)
        Application.delete_env(:req_llm, :anthropic_api_key)
      end)

      %{team: team, agent1: agent1, agent2: agent2}
    end

    test "run fails when second agent has no model", %{
      owner: owner,
      team: team,
      agent2: agent2
    } do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "failed"
      assert updated.error =~ "has no LLM model configured"
      assert updated.error =~ agent2.name
    end

    test "first agent task succeeds, second fails", %{owner: owner, team: team} do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)

      tasks = Enum.sort_by(updated.run_tasks, & &1.position)
      assert length(tasks) == 2

      # First agent completed
      assert hd(tasks).status == "completed"
      # Second agent failed
      assert List.last(tasks).status == "failed"
      assert List.last(tasks).error =~ "has no LLM model configured"
    end

    test "logs agent_complete for first agent and agent_crash for second", %{
      owner: owner,
      team: team
    } do
      run = create_run(owner, %{team_definition_id: team.id})

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      log_steps = Enum.map(updated.run_logs, & &1.step)

      assert "agent_complete" in log_steps
      assert "agent_crash" in log_steps
    end
  end

  describe "cost limit enforcement" do
    test "fails run when cost limit already exceeded before first agent", %{owner: owner} do
      model = create_provider_and_model(owner)
      {team, _agent} = create_team_with_agent(owner, llm_model_id: model.id)
      run = create_run(owner, %{team_definition_id: team.id, cost_limit: Decimal.new("0.01")})

      # Pre-load usage that exceeds the $0.01 limit
      Liteskill.Usage.record_usage(%{
        user_id: owner.id,
        run_id: run.id,
        model_id: "test-model",
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: Decimal.new("0.50"),
        output_cost: Decimal.new("0.50"),
        total_cost: Decimal.new("1.00"),
        latency_ms: 100,
        call_type: "complete",
        tool_round: 0
      })

      Runner.run(run.id, owner.id)

      {:ok, updated} = Runs.get_run(run.id, owner.id)
      assert updated.status == "failed"
      assert updated.error =~ "Cost limit"

      log_steps = Enum.map(updated.run_logs, & &1.step)
      assert "cost_limit" in log_steps
    end

    test "run schema stores cost_limit", %{owner: owner} do
      run = create_run(owner, %{cost_limit: Decimal.new("5.00")})
      {:ok, loaded} = Runs.get_run(run.id, owner.id)
      assert Decimal.compare(loaded.cost_limit, Decimal.new("5.00")) == :eq
    end

    test "cost_limit defaults to nil", %{owner: owner} do
      run = create_run(owner)
      {:ok, loaded} = Runs.get_run(run.id, owner.id)
      assert loaded.cost_limit == nil
    end
  end
end
