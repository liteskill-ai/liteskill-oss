defmodule Liteskill.Runs.Runner do
  @moduledoc """
  Executes a run by running its prompt through the configured agent(s)
  and producing deliverables (e.g. a report).

  Supports multi-agent pipeline execution: each team member runs as a separate
  task, producing per-agent report sections with handoff context between stages.
  """

  alias Liteskill.{Runs, Teams}
  alias Liteskill.Agents
  alias Liteskill.Agents.{JidoAgent, ToolResolver}
  alias Liteskill.Agents.Actions.LlmGenerate
  alias Liteskill.BuiltinTools.Reports, as: ReportsTools

  require Logger

  @doc """
  Runs a run asynchronously. Call from Task.Supervisor.

  Updates run status to running, executes the prompt, produces a report,
  and marks the run completed (or failed). Enforces `timeout_ms` from the run config.
  """
  def run(run_id, user_id) do
    with {:ok, run} <- Runs.get_run(run_id, user_id),
         {:ok, run} <- mark_running(run, user_id) do
      log(run.id, "info", "init", "Run started (timeout: #{run.timeout_ms}ms)")

      task =
        Task.Supervisor.async_nolink(Liteskill.TaskSupervisor, fn ->
          execute(run, user_id)
        end)

      case Task.yield(task, run.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          finalize(run, user_id, result)

        {:exit, reason} ->
          Logger.error("Run runner crashed: #{inspect(reason)}")
          safe_fail_run(run.id, user_id, "crash", inspect(reason))

        nil ->
          Logger.warning("Run #{run.id} timed out after #{run.timeout_ms}ms")
          safe_fail_run(run.id, user_id, "timeout", "Timed out after #{run.timeout_ms}ms")
      end
    end
  end

  defp mark_running(run, user_id) do
    Runs.update_run(run.id, user_id, %{
      status: "running",
      started_at: DateTime.utc_now()
    })
  end

  defp execute(run, user_id) do
    agents = resolve_agents(run, user_id)

    log(run.id, "info", "resolve_agents", "Resolved #{length(agents)} agent(s)", %{
      "agents" => Enum.map(agents, fn {a, m} -> %{"name" => a.name, "role" => m.role} end)
    })

    context = [user_id: user_id, run_id: run.id]
    title = build_report_title(run, agents)

    with {:ok, %{"content" => [%{"text" => create_json}]}} <-
           ReportsTools.call_tool("reports__create", %{"title" => title}, context),
         %{"id" => report_id} <- Jason.decode!(create_json) do
      log(run.id, "info", "create_report", "Created report", %{"report_id" => report_id})

      case run_pipeline(run, agents, report_id, context) do
        :ok ->
          log(run.id, "info", "complete", "Run completed successfully")
          {:ok, report_id}

        error ->
          log(run.id, "error", "pipeline", "Pipeline failed: #{inspect(error)}")
          {:error, error}
      end
    else
      error ->
        log(run.id, "error", "create_report", "Failed to create report: #{inspect(error)}")
        {:error, error}
    end
  end

  defp run_pipeline(_run, [], _report_id, _context) do
    raise "No agents assigned — cannot run without at least one agent"
  end

  defp run_pipeline(run, agents, report_id, context) do
    overview = section("Overview", overview_content(run, agents))
    :ok = write_sections(report_id, [overview], context)

    handoff_context = %{
      prompt: run.prompt,
      prior_outputs: [],
      run: run
    }

    final_context =
      agents
      |> Enum.with_index()
      |> Enum.reduce(handoff_context, fn {{agent, member}, idx}, acc ->
        run_agent_stage(run, agent, member, idx, acc, report_id, context)
      end)

    closing_sections =
      [
        section("Pipeline Summary", synthesis_content(run, agents, final_context)),
        section("Conclusion", conclusion_content(run, agents))
      ]

    write_sections(report_id, closing_sections, context)
  end

  defp run_agent_stage(run, agent, member, position, handoff, report_id, context) do
    role = member.role || "worker"
    stage_name = "Stage #{position + 1}: #{agent.name} (#{role})"

    log(run.id, "info", "agent_start", "Starting #{stage_name}", %{
      "agent" => agent.name,
      "role" => role,
      "strategy" => agent.strategy,
      "model" => if(agent.llm_model, do: agent.llm_model.name, else: nil),
      "position" => position
    })

    {:ok, task} =
      Runs.add_task(run.id, %{
        name: stage_name,
        description: member.description || "#{role} stage using #{agent.strategy} strategy",
        status: "running",
        position: position,
        agent_definition_id: agent.id,
        started_at: DateTime.utc_now()
      })

    start_time = System.monotonic_time(:millisecond)

    try do
      agent_output = execute_agent(agent, member, handoff, context, run.id)

      agent_sections = [
        section("#{stage_name}/Configuration", agent_config_content(agent)),
        section("#{stage_name}/Analysis", agent_output.analysis),
        section("#{stage_name}/Output", agent_output.output)
      ]

      result = write_sections(report_id, agent_sections, context)
      duration_ms = System.monotonic_time(:millisecond) - start_time
      complete_task(task, result, duration_ms, "#{agent.name} (#{role}) completed")

      log(run.id, "info", "agent_complete", "Completed #{stage_name} in #{duration_ms}ms", %{
        "agent" => agent.name,
        "duration_ms" => duration_ms,
        "output_length" => String.length(agent_output.output),
        "messages" => agent_output[:messages] || []
      })

      %{
        handoff
        | prior_outputs:
            handoff.prior_outputs ++
              [%{agent: agent.name, role: role, output: agent_output.output}]
      }
    rescue
      e ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Runs.update_task(task.id, %{
          status: "failed",
          error: Exception.message(e),
          duration_ms: duration_ms,
          completed_at: DateTime.utc_now()
        })

        log(run.id, "error", "agent_crash", "#{stage_name} crashed: #{Exception.message(e)}", %{
          "agent" => agent.name,
          "duration_ms" => duration_ms
        })

        reraise e, __STACKTRACE__
    end
  end

  defp execute_agent(agent, member, handoff, context, run_id) do
    user_id = Keyword.fetch!(context, :user_id)
    role = member.role || "worker"

    unless agent.llm_model do
      raise "Agent '#{agent.name}' has no LLM model configured"
    end

    {tools, tool_servers} = ToolResolver.resolve(agent, user_id)

    log(
      run_id,
      "info",
      "tool_resolve",
      "Resolved #{length(tools)} tool(s) for #{agent.name}",
      %{
        "agent" => agent.name,
        "tool_count" => length(tools),
        "tool_names" => Enum.map(tools, &get_in(&1, ["toolSpec", "name"]))
      }
    )

    jido_agent =
      JidoAgent.new(
        state: %{
          agent_name: agent.name,
          system_prompt: agent.system_prompt || "",
          backstory: agent.backstory || "",
          opinions: agent.opinions || %{},
          role: role,
          strategy: agent.strategy,
          llm_model: agent.llm_model,
          tools: tools,
          tool_servers: tool_servers,
          user_id: user_id,
          run_id: run_id,
          prompt: handoff.prompt,
          prior_context: format_prior_context(handoff.prior_outputs)
        }
      )

    log(run_id, "info", "llm_call", "Calling LLM for #{agent.name}", %{
      "agent" => agent.name,
      "model" => agent.llm_model.name
    })

    case LlmGenerate.run(%{}, %{state: jido_agent.state}) do
      {:ok, result} ->
        %{analysis: result.analysis, output: result.output, messages: result[:messages] || []}

      {:error, reason} ->
        raise "Agent '#{agent.name}' LLM call failed: #{inspect(reason)}"
    end
  end

  @max_prior_context_chars 8_000

  defp format_prior_context([]), do: ""

  defp format_prior_context(outputs) do
    Enum.map_join(outputs, "\n\n", fn %{agent: name, role: role, output: output} ->
      truncated = String.slice(output || "", 0, @max_prior_context_chars)

      "--- #{name} (#{role}) ---\n#{truncated}"
    end)
  end

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
    Runs.update_task(task.id, %{
      status: "completed",
      output_summary: summary,
      duration_ms: duration_ms,
      completed_at: DateTime.utc_now()
    })
  end

  defp complete_task(task, _error, _duration_ms, _summary) do
    Runs.update_task(task.id, %{
      status: "failed",
      error: "Failed to write report sections",
      completed_at: DateTime.utc_now()
    })
  end

  defp finalize(run, user_id, {:ok, report_id}) do
    Runs.update_run(run.id, user_id, %{
      status: "completed",
      deliverables: %{"report_id" => report_id},
      completed_at: DateTime.utc_now()
    })
  end

  defp finalize(run, user_id, {:error, reason}) do
    Runs.update_run(run.id, user_id, %{
      status: "failed",
      error: inspect(reason),
      completed_at: DateTime.utc_now()
    })
  end

  # Resolve all agents from team, sorted by position
  defp resolve_agents(run, user_id) do
    case run.team_definition_id do
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

  defp build_report_title(run, agents) do
    agent_names = Enum.map_join(agents, ", ", fn {agent, _} -> agent.name end)
    "#{run.name} — #{agent_names}"
  end

  defp overview_content(run, agents) do
    agent_list =
      agents
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{agent, member}, idx} ->
        role = member.role || "worker"
        "#{idx}. **#{agent.name}** — #{role} (#{agent.strategy})"
      end)

    "**Prompt:** #{run.prompt}\n\n" <>
      "**Topology:** #{run.topology}\n\n" <>
      "**Pipeline Stages:**\n#{agent_list}\n\n" <>
      "**Execution:** Sequential pipeline — each agent processes in order, " <>
      "passing context forward to the next stage."
  end

  defp synthesis_content(run, agents, final_context) do
    stage_summary =
      final_context.prior_outputs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%{agent: name, role: role}, idx} ->
        "#{idx}. **#{name}** (#{role}) — completed successfully"
      end)

    "## Pipeline Execution Summary\n\n" <>
      "The run **#{run.name}** was executed through a " <>
      "**#{length(agents)}-stage pipeline**.\n\n" <>
      "**Stages completed:**\n#{stage_summary}\n\n" <>
      "All #{length(agents)} agents processed the prompt sequentially, " <>
      "each building on the outputs of prior stages."
  end

  defp conclusion_content(run, agents) do
    "Run **#{run.name}** completed successfully through a " <>
      "**#{length(agents)}-agent pipeline**. " <>
      "Each agent contributed their specialized analysis, " <>
      "producing a comprehensive deliverable. " <>
      "This report was generated automatically by the Agent Studio runner."
  end

  defp agent_config_content(agent) do
    lines = [
      "- **Name:** #{agent.name}",
      "- **Strategy:** #{agent.strategy}",
      "- **Status:** #{agent.status}"
    ]

    lines = lines ++ ["- **Model:** #{agent.llm_model.name}"]

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

  defp safe_fail_run(run_id, user_id, step, error_message) do
    log(run_id, "error", step, error_message)

    Runs.update_run(run_id, user_id, %{
      status: "failed",
      error: error_message,
      completed_at: DateTime.utc_now()
    })
  rescue
    # coveralls-ignore-start
    e ->
      Logger.error("Failed to update run #{run_id} after #{step}: #{Exception.message(e)}")
      # coveralls-ignore-stop
  end

  defp log(run_id, level, step, message, metadata \\ %{}) do
    Runs.add_log(run_id, level, step, message, metadata)
  end
end
