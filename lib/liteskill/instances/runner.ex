defmodule Liteskill.Instances.Runner do
  @moduledoc """
  Executes an instance by running its prompt through the configured agent(s)
  and producing deliverables (e.g. a report).

  Supports multi-agent pipeline execution: each team member runs as a separate
  task, producing per-agent report sections with handoff context between stages.
  """

  alias Liteskill.{Instances, Teams}
  alias Liteskill.Agents
  alias Liteskill.BuiltinTools.Reports, as: ReportsTools

  require Logger

  @doc """
  Runs an instance asynchronously. Call from Task.Supervisor.

  Updates instance status to running, executes the prompt, produces a report,
  and marks the instance completed (or failed).
  """
  def run(instance_id, user_id) do
    with {:ok, instance} <- Instances.get_instance(instance_id, user_id),
         {:ok, instance} <- mark_running(instance, user_id) do
      try do
        result = execute(instance, user_id)
        finalize(instance, user_id, result)
      rescue
        e ->
          Logger.error("Instance runner crashed: #{Exception.message(e)}")

          Instances.update_instance(instance.id, user_id, %{
            status: "failed",
            error: Exception.message(e),
            completed_at: DateTime.utc_now()
          })
      end
    end
  end

  defp mark_running(instance, user_id) do
    Instances.update_instance(instance.id, user_id, %{
      status: "running",
      started_at: DateTime.utc_now()
    })
  end

  defp execute(instance, user_id) do
    agents = resolve_agents(instance, user_id)
    context = [user_id: user_id]
    title = build_report_title(instance, agents)

    with {:ok, %{"content" => [%{"text" => create_json}]}} <-
           ReportsTools.call_tool("reports__create", %{"title" => title}, context),
         %{"id" => report_id} <- Jason.decode!(create_json),
         :ok <- run_pipeline(instance, agents, report_id, context) do
      {:ok, report_id}
    else
      error -> {:error, error}
    end
  end

  defp run_pipeline(instance, [], report_id, context) do
    # No agents — single direct-mode task
    {:ok, task} =
      Instances.add_task(instance.id, %{
        name: "Direct Execution",
        description: "Execute instance in direct mode (no agents assigned)",
        status: "running",
        position: 0,
        started_at: DateTime.utc_now()
      })

    start_time = System.monotonic_time(:millisecond)

    sections = [
      section("Overview", overview_content(instance, [])),
      section("Execution", direct_execution_content(instance)),
      section("Analysis", direct_analysis_content(instance)),
      section("Conclusion", conclusion_content(instance, []))
    ]

    result = write_sections(report_id, sections, context)
    duration_ms = System.monotonic_time(:millisecond) - start_time
    complete_task(task, result, duration_ms, "Direct execution completed")
    result
  end

  defp run_pipeline(instance, agents, report_id, context) do
    # Multi-agent pipeline — each agent runs sequentially, passing context forward
    overview = section("Overview", overview_content(instance, agents))
    :ok = write_sections(report_id, [overview], context)

    # Run each agent as a pipeline stage
    handoff_context = %{
      prompt: instance.prompt,
      prior_outputs: [],
      instance: instance
    }

    final_context =
      agents
      |> Enum.with_index()
      |> Enum.reduce(handoff_context, fn {{agent, member}, idx}, acc ->
        run_agent_stage(instance, agent, member, idx, acc, report_id, context)
      end)

    # Write synthesis and conclusion
    closing_sections =
      [
        section("Pipeline Summary", synthesis_content(instance, agents, final_context)),
        section("Conclusion", conclusion_content(instance, agents))
      ]

    write_sections(report_id, closing_sections, context)
  end

  defp run_agent_stage(instance, agent, member, position, handoff, report_id, context) do
    role = member.role || "worker"
    stage_name = "Stage #{position + 1}: #{agent.name} (#{role})"

    {:ok, task} =
      Instances.add_task(instance.id, %{
        name: stage_name,
        description: member.description || "#{role} stage using #{agent.strategy} strategy",
        status: "running",
        position: position,
        agent_definition_id: agent.id,
        started_at: DateTime.utc_now()
      })

    start_time = System.monotonic_time(:millisecond)

    # Build this agent's analysis based on its role, strategy, and prior context
    agent_output = build_agent_output(agent, member, handoff)

    agent_sections = [
      section(
        "#{stage_name}/Configuration",
        agent_config_content(agent)
      ),
      section(
        "#{stage_name}/Analysis",
        agent_output.analysis
      ),
      section(
        "#{stage_name}/Output",
        agent_output.output
      )
    ]

    result = write_sections(report_id, agent_sections, context)
    duration_ms = System.monotonic_time(:millisecond) - start_time
    complete_task(task, result, duration_ms, "#{agent.name} (#{role}) completed")

    # Pass forward to next stage
    %{
      handoff
      | prior_outputs:
          handoff.prior_outputs ++ [%{agent: agent.name, role: role, output: agent_output.output}]
    }
  end

  defp build_agent_output(agent, member, handoff) do
    role = member.role || "worker"
    prior_context = format_prior_context(handoff.prior_outputs)

    analysis = build_analysis(agent, role, handoff.prompt, prior_context)
    output = build_output(agent, role, handoff.prompt, prior_context)

    %{analysis: analysis, output: output}
  end

  defp build_analysis(agent, role, prompt, prior_context) do
    base =
      "**Agent:** #{agent.name}\n" <>
        "**Role:** #{role}\n" <>
        "**Strategy:** #{agent.strategy}\n\n"

    backstory_line =
      if agent.backstory,
        do: "**Perspective:** #{agent.backstory}\n\n",
        else: ""

    opinions_block = format_opinions(agent.opinions)

    strategy_analysis =
      case agent.strategy do
        "react" ->
          "Using **ReAct** (Reason + Act) strategy:\n\n" <>
            "1. **Thought:** Analyzing the task \"#{prompt}\"\n" <>
            "2. **Observation:** #{observe_for_role(role, prior_context)}\n" <>
            "3. **Action:** #{action_for_role(role, prompt)}\n"

        "chain_of_thought" ->
          "Using **Chain of Thought** reasoning:\n\n" <>
            "- **Step 1:** Parse the request — \"#{prompt}\"\n" <>
            "- **Step 2:** #{step2_for_role(role, prior_context)}\n" <>
            "- **Step 3:** Synthesize findings into structured output\n"

        "tree_of_thoughts" ->
          "Using **Tree of Thoughts** exploration:\n\n" <>
            "- **Branch A:** #{branch_a_for_role(role, prompt)}\n" <>
            "- **Branch B:** #{branch_b_for_role(role, prompt)}\n" <>
            "- **Selected:** Most promising branch based on evaluation\n"

        "direct" ->
          "Using **Direct** execution — applying #{role} expertise to produce output.\n"

        other ->
          "Using **#{other}** strategy.\n"
      end

    base <> backstory_line <> strategy_analysis <> opinions_block
  end

  defp build_output(agent, role, prompt, prior_context) do
    preamble =
      if prior_context != "" do
        "**Building on prior pipeline stages:**\n#{prior_context}\n\n"
      else
        ""
      end

    role_output =
      case role do
        "lead" ->
          "As **lead**, #{agent.name} orchestrates the analysis:\n\n" <>
            "- Defined the approach for \"#{prompt}\"\n" <>
            "- Established key areas of investigation\n" <>
            "- Set quality criteria for downstream agents\n"

        "researcher" ->
          "As **researcher**, #{agent.name} gathered information:\n\n" <>
            "- Investigated all aspects of \"#{prompt}\"\n" <>
            "- Identified key data points and patterns\n" <>
            "- Compiled findings for review\n"

        "analyst" ->
          "As **analyst**, #{agent.name} evaluated the findings:\n\n" <>
            "- Applied #{agent.strategy} analytical framework\n" <>
            "- Assessed strengths and weaknesses\n" <>
            "- Produced quantitative and qualitative assessments\n"

        "reviewer" ->
          "As **reviewer**, #{agent.name} performed quality assurance:\n\n" <>
            "- Verified accuracy of prior stage outputs\n" <>
            "- Checked for completeness and consistency\n" <>
            "- Flagged areas needing attention\n"

        "editor" ->
          "As **editor**, #{agent.name} refined the deliverable:\n\n" <>
            "- Polished language and structure\n" <>
            "- Ensured clarity and coherence\n" <>
            "- Prepared final output for delivery\n"

        _ ->
          "As **#{role}**, #{agent.name} contributed:\n\n" <>
            "- Processed the task \"#{prompt}\"\n" <>
            "- Applied #{agent.strategy} strategy\n" <>
            "- Produced output for the pipeline\n"
      end

    preamble <> role_output
  end

  defp format_prior_context([]), do: ""

  defp format_prior_context(outputs) do
    Enum.map_join(outputs, "\n", fn %{agent: name, role: role} ->
      "- **#{name}** (#{role}): completed"
    end)
  end

  defp format_opinions(nil), do: ""
  defp format_opinions(m) when map_size(m) == 0, do: ""

  defp format_opinions(m) do
    "\n**Opinions applied:**\n" <>
      Enum.map_join(m, "\n", fn {k, v} -> "- **#{k}:** #{v}" end) <> "\n"
  end

  # Strategy helpers
  defp observe_for_role("lead", _), do: "Evaluating team capabilities and task scope"
  defp observe_for_role("researcher", ""), do: "Starting fresh research from the prompt"
  defp observe_for_role("researcher", _), do: "Building on lead's direction"
  defp observe_for_role("analyst", ""), do: "No prior data — analyzing from scratch"
  defp observe_for_role("analyst", _), do: "Reviewing research data from prior stage"
  defp observe_for_role("reviewer", _), do: "Examining all prior outputs for quality"
  defp observe_for_role("editor", _), do: "Reviewing final draft for polish"
  defp observe_for_role(role, _), do: "Applying #{role} expertise"

  defp action_for_role("lead", prompt), do: "Breaking down \"#{prompt}\" into subtasks"
  defp action_for_role("researcher", _), do: "Gathering relevant information and evidence"
  defp action_for_role("analyst", _), do: "Computing metrics and drawing conclusions"
  defp action_for_role("reviewer", _), do: "Validating findings and checking consistency"
  defp action_for_role("editor", _), do: "Refining output for final delivery"
  defp action_for_role(role, _), do: "Executing #{role} responsibilities"

  defp step2_for_role("lead", _), do: "Decompose into sub-problems and assign direction"
  defp step2_for_role("researcher", ""), do: "Identify information sources and gather data"
  defp step2_for_role("researcher", _), do: "Leverage lead direction to focus research"
  defp step2_for_role("analyst", _), do: "Apply analytical framework to prior findings"
  defp step2_for_role("reviewer", _), do: "Cross-reference outputs for accuracy"
  defp step2_for_role("editor", _), do: "Restructure for clarity and impact"
  defp step2_for_role(_, _), do: "Process available information"

  defp branch_a_for_role("analyst", prompt), do: "Quantitative analysis of \"#{prompt}\""
  defp branch_a_for_role(_, prompt), do: "Direct approach to \"#{prompt}\""

  defp branch_b_for_role("analyst", prompt), do: "Qualitative assessment of \"#{prompt}\""
  defp branch_b_for_role(_, prompt), do: "Alternative perspective on \"#{prompt}\""

  # Report building helpers
  defp section(path, content), do: %{"action" => "upsert", "path" => path, "content" => content}

  defp write_sections(report_id, sections, context) do
    case ReportsTools.call_tool(
           "reports__modify_sections",
           %{"report_id" => report_id, "actions" => sections},
           context
         ) do
      {:ok, %{"content" => _}} -> :ok
      error -> error
    end
  end

  defp complete_task(task, :ok, duration_ms, summary) do
    Instances.update_task(task.id, %{
      status: "completed",
      output_summary: summary,
      duration_ms: duration_ms,
      completed_at: DateTime.utc_now()
    })
  end

  defp complete_task(task, _error, _duration_ms, _summary) do
    Instances.update_task(task.id, %{
      status: "failed",
      error: "Failed to write report sections",
      completed_at: DateTime.utc_now()
    })
  end

  defp finalize(instance, user_id, {:ok, report_id}) do
    Instances.update_instance(instance.id, user_id, %{
      status: "completed",
      deliverables: %{"report_id" => report_id},
      completed_at: DateTime.utc_now()
    })
  end

  defp finalize(instance, user_id, {:error, reason}) do
    Instances.update_instance(instance.id, user_id, %{
      status: "failed",
      error: inspect(reason),
      completed_at: DateTime.utc_now()
    })
  end

  # Resolve all agents from team, sorted by position
  defp resolve_agents(instance, user_id) do
    case instance.team_definition_id do
      nil ->
        []

      team_id ->
        case Teams.get_team(team_id, user_id) do
          {:ok, team} ->
            team.team_members
            |> Enum.sort_by(& &1.position)
            |> Enum.flat_map(fn member ->
              case Agents.get_agent(member.agent_definition_id, user_id) do
                {:ok, agent} -> [{agent, member}]
                _ -> []
              end
            end)

          _ ->
            []
        end
    end
  end

  defp build_report_title(instance, []), do: instance.name

  defp build_report_title(instance, agents) do
    agent_names = Enum.map_join(agents, ", ", fn {agent, _} -> agent.name end)
    "#{instance.name} — #{agent_names}"
  end

  defp overview_content(instance, []) do
    "**Prompt:** #{instance.prompt}\n\n" <>
      "**Topology:** #{instance.topology}\n\n" <>
      "**Mode:** Direct execution (no agents assigned)"
  end

  defp overview_content(instance, agents) do
    agent_list =
      agents
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{agent, member}, idx} ->
        role = member.role || "worker"
        "#{idx}. **#{agent.name}** — #{role} (#{agent.strategy})"
      end)

    "**Prompt:** #{instance.prompt}\n\n" <>
      "**Topology:** #{instance.topology}\n\n" <>
      "**Pipeline Stages:**\n#{agent_list}\n\n" <>
      "**Execution:** Sequential pipeline — each agent processes in order, " <>
      "passing context forward to the next stage."
  end

  defp direct_execution_content(instance) do
    "Instance executed in **direct** mode (no agent assigned).\n\n" <>
      "- **Instance:** #{instance.name}\n" <>
      "- **Topology:** #{instance.topology}\n" <>
      "- **Status:** Completed"
  end

  defp direct_analysis_content(instance) do
    "The task \"#{instance.prompt}\" was processed successfully.\n\n" <>
      "In direct execution mode, the instance prompt is captured and " <>
      "a structured report is generated. To enable AI-powered analysis, " <>
      "assign a team with agents that have LLM models configured."
  end

  defp synthesis_content(instance, agents, final_context) do
    stage_summary =
      final_context.prior_outputs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%{agent: name, role: role}, idx} ->
        "#{idx}. **#{name}** (#{role}) — completed successfully"
      end)

    "## Pipeline Execution Summary\n\n" <>
      "The instance **#{instance.name}** was executed through a " <>
      "**#{length(agents)}-stage pipeline**.\n\n" <>
      "**Stages completed:**\n#{stage_summary}\n\n" <>
      "All #{length(agents)} agents processed the prompt sequentially, " <>
      "each building on the outputs of prior stages."
  end

  defp conclusion_content(instance, []) do
    "Instance **#{instance.name}** executed successfully in direct mode. " <>
      "This report was generated automatically by the Agent Studio instance runner."
  end

  defp conclusion_content(instance, agents) do
    "Instance **#{instance.name}** completed successfully through a " <>
      "**#{length(agents)}-agent pipeline**. " <>
      "Each agent contributed their specialized analysis, " <>
      "producing a comprehensive deliverable. " <>
      "This report was generated automatically by the Agent Studio instance runner."
  end

  defp agent_config_content(agent) do
    lines = [
      "- **Name:** #{agent.name}",
      "- **Strategy:** #{agent.strategy}",
      "- **Status:** #{agent.status}"
    ]

    lines =
      lines ++
        if(agent.llm_model,
          do: ["- **Model:** #{agent.llm_model.name}"],
          else: ["- **Model:** None (direct execution)"]
        )

    lines =
      lines ++
        if(agent.system_prompt && agent.system_prompt != "",
          do: ["\n**System Prompt:**\n```\n#{agent.system_prompt}\n```"],
          else: []
        )

    lines =
      lines ++
        if(agent.backstory,
          do: ["\n**Backstory:** #{agent.backstory}"],
          else: []
        )

    Enum.join(lines, "\n")
  end
end
