defmodule Liteskill.Runs.ReportBuilderTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Runs
  alias Liteskill.Runs.ReportBuilder

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rb-owner-#{System.unique_integer([:positive])}@example.com",
        name: "RB Owner",
        oidc_sub: "rb-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  defp create_run(owner, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Test Run #{System.unique_integer([:positive])}",
          prompt: "Analyze this",
          topology: "pipeline",
          user_id: owner.id
        },
        overrides
      )

    {:ok, run} = Runs.create_run(attrs)
    {:ok, run} = Runs.get_run(run.id, owner.id)
    run
  end

  defp fake_agent(name, opts \\ []) do
    %{
      name: name,
      strategy: Keyword.get(opts, :strategy, "react"),
      status: "active",
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful agent."),
      backstory: Keyword.get(opts, :backstory, "A test agent"),
      llm_model: %{name: "test-model"}
    }
  end

  defp fake_member(opts \\ []) do
    %{role: Keyword.get(opts, :role, "worker")}
  end

  # ---------------------------------------------------------------------------
  # section/2
  # ---------------------------------------------------------------------------

  describe "section/2" do
    test "builds an upsert action map" do
      result = ReportBuilder.section("Overview", "Some content")

      assert result == %{
               "action" => "upsert",
               "path" => "Overview",
               "content" => "Some content"
             }
    end
  end

  # ---------------------------------------------------------------------------
  # build_report_title/2
  # ---------------------------------------------------------------------------

  describe "build_report_title/2" do
    test "combines run name with agent names" do
      run = %{name: "Q4 Analysis"}
      agents = [{fake_agent("Researcher"), fake_member()}, {fake_agent("Writer"), fake_member()}]

      result = ReportBuilder.build_report_title(run, agents)
      assert result == "Q4 Analysis — Researcher, Writer"
    end

    test "handles single agent" do
      run = %{name: "Solo Run"}
      agents = [{fake_agent("Solo"), fake_member()}]

      assert ReportBuilder.build_report_title(run, agents) == "Solo Run — Solo"
    end
  end

  # ---------------------------------------------------------------------------
  # overview_content/2
  # ---------------------------------------------------------------------------

  describe "overview_content/2" do
    test "includes prompt, topology, and agent list" do
      run = %{prompt: "Analyze the market", topology: "pipeline"}

      agents = [
        {fake_agent("Researcher"), fake_member(role: "analyst")},
        {fake_agent("Writer"), fake_member(role: "writer")}
      ]

      result = ReportBuilder.overview_content(run, agents)

      assert result =~ "**Prompt:** Analyze the market"
      assert result =~ "**Topology:** pipeline"
      assert result =~ "1. **Researcher** — analyst (react)"
      assert result =~ "2. **Writer** — writer (react)"
      assert result =~ "Sequential pipeline"
    end

    test "uses worker as default role" do
      run = %{prompt: "test", topology: "pipeline"}
      agents = [{fake_agent("Agent"), %{role: nil}}]

      result = ReportBuilder.overview_content(run, agents)
      assert result =~ "worker"
    end
  end

  # ---------------------------------------------------------------------------
  # synthesis_content/3
  # ---------------------------------------------------------------------------

  describe "synthesis_content/3" do
    test "summarizes completed pipeline stages" do
      run = %{name: "Test Run"}
      agents = [{fake_agent("A"), fake_member()}, {fake_agent("B"), fake_member()}]

      final_context = %{
        prior_outputs: [
          %{agent: "A", role: "analyst", output: "..."},
          %{agent: "B", role: "writer", output: "..."}
        ]
      }

      result = ReportBuilder.synthesis_content(run, agents, final_context)

      assert result =~ "Pipeline Execution Summary"
      assert result =~ "**Test Run**"
      assert result =~ "**2-stage pipeline**"
      assert result =~ "1. **A** (analyst) — completed successfully"
      assert result =~ "2. **B** (writer) — completed successfully"
    end
  end

  # ---------------------------------------------------------------------------
  # conclusion_content/2
  # ---------------------------------------------------------------------------

  describe "conclusion_content/2" do
    test "includes run name and agent count" do
      run = %{name: "Market Analysis"}
      agents = [{fake_agent("A"), fake_member()}, {fake_agent("B"), fake_member()}]

      result = ReportBuilder.conclusion_content(run, agents)

      assert result =~ "**Market Analysis**"
      assert result =~ "**2-agent pipeline**"
      assert result =~ "Agent Studio runner"
    end
  end

  # ---------------------------------------------------------------------------
  # agent_config_content/1
  # ---------------------------------------------------------------------------

  describe "agent_config_content/1" do
    test "includes name, strategy, status, and model" do
      agent = fake_agent("Researcher", strategy: "chain_of_thought")

      result = ReportBuilder.agent_config_content(agent)

      assert result =~ "**Name:** Researcher"
      assert result =~ "**Strategy:** chain_of_thought"
      assert result =~ "**Status:** active"
      assert result =~ "**Model:** test-model"
    end

    test "includes system prompt when present" do
      agent = fake_agent("Agent", system_prompt: "Be concise and accurate.")

      result = ReportBuilder.agent_config_content(agent)

      assert result =~ "**System Prompt:**"
      assert result =~ "Be concise and accurate."
    end

    test "omits system prompt when empty" do
      agent = fake_agent("Agent", system_prompt: "")

      result = ReportBuilder.agent_config_content(agent)

      refute result =~ "System Prompt"
    end

    test "omits system prompt when nil" do
      agent = fake_agent("Agent", system_prompt: nil)

      result = ReportBuilder.agent_config_content(agent)

      refute result =~ "System Prompt"
    end

    test "includes backstory when present" do
      agent = fake_agent("Agent", backstory: "A seasoned analyst")

      result = ReportBuilder.agent_config_content(agent)

      assert result =~ "**Backstory:** A seasoned analyst"
    end

    test "omits backstory when nil" do
      agent = fake_agent("Agent", backstory: nil)

      result = ReportBuilder.agent_config_content(agent)

      refute result =~ "Backstory"
    end
  end

  # ---------------------------------------------------------------------------
  # find_existing_report/1
  # ---------------------------------------------------------------------------

  describe "find_existing_report/1" do
    test "returns report_id from deliverables when present" do
      run = %{deliverables: %{"report_id" => "rpt_123"}, run_logs: []}

      assert ReportBuilder.find_existing_report(run) == "rpt_123"
    end

    test "returns report_id from create_report log when no deliverable" do
      run = %{
        deliverables: %{},
        run_logs: [
          %{step: "start", metadata: %{}},
          %{step: "create_report", metadata: %{"report_id" => "rpt_456"}}
        ]
      }

      assert ReportBuilder.find_existing_report(run) == "rpt_456"
    end

    test "returns nil when no deliverable and no create_report log" do
      run = %{
        deliverables: %{},
        run_logs: [
          %{step: "start", metadata: %{}},
          %{step: "agent_complete", metadata: %{"agent" => "A"}}
        ]
      }

      assert ReportBuilder.find_existing_report(run) == nil
    end

    test "returns nil when deliverables is nil" do
      run = %{deliverables: nil, run_logs: []}
      assert ReportBuilder.find_existing_report(run) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # get_or_create_report/3 (integration — needs DB)
  # ---------------------------------------------------------------------------

  describe "get_or_create_report/3" do
    test "creates a new report when none exists", %{owner: owner} do
      run = create_run(owner)
      agents = [{fake_agent("Agent1"), fake_member()}]
      context = [user_id: owner.id]

      assert {:ok, report_id} = ReportBuilder.get_or_create_report(run, agents, context)
      assert is_binary(report_id)

      # Verify a create_report log was added
      Process.sleep(50)
      {:ok, updated_run} = Runs.get_run(run.id, owner.id)

      create_log =
        Enum.find(updated_run.run_logs, &(&1.step == "create_report"))

      assert create_log
      assert create_log.metadata["report_id"] == report_id
    end

    test "reuses existing report from deliverables", %{owner: owner} do
      run = create_run(owner)

      # Manually set deliverables with a report_id
      Runs.update_run(run.id, owner.id, %{deliverables: %{"report_id" => "existing_rpt"}})
      {:ok, run} = Runs.get_run(run.id, owner.id)

      agents = [{fake_agent("Agent1"), fake_member()}]
      context = [user_id: owner.id]

      assert {:ok, "existing_rpt"} = ReportBuilder.get_or_create_report(run, agents, context)
    end
  end

  # ---------------------------------------------------------------------------
  # write_sections/3 (integration — needs DB)
  # ---------------------------------------------------------------------------

  describe "write_sections/3" do
    test "writes sections to an existing report", %{owner: owner} do
      run = create_run(owner)
      agents = [{fake_agent("Agent1"), fake_member()}]
      context = [user_id: owner.id]

      {:ok, report_id} = ReportBuilder.get_or_create_report(run, agents, context)

      sections = [
        ReportBuilder.section("Overview", "Test overview content"),
        ReportBuilder.section("Analysis", "Test analysis content")
      ]

      assert :ok = ReportBuilder.write_sections(report_id, sections, context)
    end
  end
end
