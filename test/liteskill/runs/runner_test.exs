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
      assert "crash" in log_steps
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
end
