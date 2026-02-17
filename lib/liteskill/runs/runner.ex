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
  alias Liteskill.Runs.{ReportBuilder, ResumeHandler}

  require Logger

  # Delegate extract_handoff_summary so existing callers (and tests) still work.
  defdelegate extract_handoff_summary(output), to: ResumeHandler

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
      started_at: DateTime.utc_now(),
      error: nil,
      completed_at: nil
    })
  end

  defp execute(run, user_id) do
    agents = resolve_agents(run, user_id)

    log(run.id, "info", "resolve_agents", "Resolved #{length(agents)} agent(s)", %{
      "agents" => Enum.map(agents, fn {a, m} -> %{"name" => a.name, "role" => m.role} end)
    })

    context = [user_id: user_id, run_id: run.id, cost_limit: run.cost_limit]

    case ReportBuilder.get_or_create_report(run, agents, context) do
      {:ok, report_id} ->
        case run_pipeline(run, agents, report_id, context) do
          :ok ->
            log(run.id, "info", "complete", "Run completed successfully")
            {:ok, report_id}

          {:error, reason} ->
            log(run.id, "error", "pipeline", "Pipeline failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        log(run.id, "error", "create_report", "Failed to create report: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_pipeline(_run, [], _report_id, _context) do
    raise "No agents assigned — cannot run without at least one agent"
  end

  defp run_pipeline(run, agents, report_id, context) do
    # Determine which stages already completed (for resume)
    completed_tasks =
      run.run_tasks
      |> Enum.filter(&(&1.status == "completed"))
      |> Map.new(&{&1.position, &1})

    # Find first position that needs to run
    resume_from =
      Enum.find_value(0..(length(agents) - 1), length(agents), fn idx ->
        unless Map.has_key?(completed_tasks, idx), do: idx
      end)

    is_resume = resume_from > 0

    unless is_resume do
      overview = ReportBuilder.section("Overview", ReportBuilder.overview_content(run, agents))
      :ok = ReportBuilder.write_sections(report_id, [overview], context)
    end

    # Build handoff from previously completed stages
    prior_outputs =
      agents
      |> Enum.with_index()
      |> Enum.take(resume_from)
      |> Enum.map(fn {{agent, member}, _idx} ->
        summary = ResumeHandler.find_handoff_summary(run.run_logs, agent.name) || ""
        %{agent: agent.name, role: member.role || "worker", output: summary}
      end)

    handoff_context = %{
      prompt: run.prompt,
      prior_outputs: prior_outputs,
      report_id: report_id,
      run: run
    }

    if is_resume do
      log(
        run.id,
        "info",
        "resume",
        "Resuming from Stage #{resume_from + 1}, " <>
          "skipping #{resume_from} completed stage(s)"
      )
    end

    result =
      agents
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, handoff_context}, fn {{agent, member}, idx}, {:ok, acc} ->
        cond do
          idx < resume_from ->
            {:cont, {:ok, acc}}

          cost_limit_exceeded?(run) ->
            reason = "Cost limit of $#{run.cost_limit} exceeded"
            log(run.id, "error", "cost_limit", reason)
            {:halt, {:error, reason}}

          true ->
            case run_agent_stage(run, agent, member, idx, acc, report_id, context) do
              {:ok, updated_handoff} -> {:cont, {:ok, updated_handoff}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)

    case result do
      {:ok, final_context} ->
        closing_sections =
          [
            ReportBuilder.section(
              "Pipeline Summary",
              ReportBuilder.synthesis_content(run, agents, final_context)
            ),
            ReportBuilder.section("Conclusion", ReportBuilder.conclusion_content(run, agents))
          ]

        ReportBuilder.write_sections(report_id, closing_sections, context)

      {:error, reason} ->
        {:error, reason}
    end
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
    stage_started_at = DateTime.utc_now()

    # Check for crash messages from a previous failed attempt
    resume_messages = ResumeHandler.find_crash_messages(run.run_logs, agent.name)

    if resume_messages do
      log(run.id, "info", "agent_resume", "Resuming #{stage_name} from saved context", %{
        "agent" => agent.name,
        "message_count" => length(resume_messages)
      })
    end

    # Wrap execute_agent so raises (e.g. no LLM model) become error tuples
    agent_result =
      try do
        execute_agent(agent, member, handoff, context, run.id, resume_messages)
      rescue
        e ->
          Logger.error(
            "Agent #{agent.name} raised during execution:\n" <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {:error, Exception.message(e), []}
      end

    case agent_result do
      {:ok, agent_output} ->
        agent_sections = [
          ReportBuilder.section(
            "#{stage_name}/Configuration",
            ReportBuilder.agent_config_content(agent)
          ),
          ReportBuilder.section("#{stage_name}/Analysis", agent_output.analysis),
          ReportBuilder.section("#{stage_name}/Output", agent_output.output)
        ]

        result = ReportBuilder.write_sections(report_id, agent_sections, context)
        duration_ms = System.monotonic_time(:millisecond) - start_time
        complete_task(task, result, duration_ms, "#{agent.name} (#{role}) completed")

        handoff_summary = ResumeHandler.extract_handoff_summary(agent_output.output)

        # Aggregate per-stage usage for observability
        stage_usage = Liteskill.Usage.usage_by_run_since(run.id, stage_started_at)

        log(run.id, "info", "agent_complete", "Completed #{stage_name} in #{duration_ms}ms", %{
          "agent" => agent.name,
          "duration_ms" => duration_ms,
          "output_length" => String.length(agent_output.output),
          "output" => agent_output.output,
          "handoff_summary" => handoff_summary,
          "messages" => agent_output.messages,
          "usage" => format_stage_usage(stage_usage)
        })

        {:ok,
         %{
           handoff
           | prior_outputs:
               handoff.prior_outputs ++
                 [%{agent: agent.name, role: role, output: handoff_summary}]
         }}

      {:error, reason, messages} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Runs.update_task(task.id, %{
          status: "failed",
          error: reason,
          duration_ms: duration_ms,
          completed_at: DateTime.utc_now()
        })

        log(run.id, "error", "agent_crash", "#{stage_name} crashed: #{reason}", %{
          "agent" => agent.name,
          "duration_ms" => duration_ms,
          "messages" => messages
        })

        {:error, reason}
    end
  end

  defp execute_agent(agent, member, handoff, context, run_id, resume_messages) do
    user_id = Keyword.fetch!(context, :user_id)
    role = member.role || "worker"

    unless agent.llm_model do
      raise "Agent '#{agent.name}' has no LLM model configured"
    end

    {tools, tool_servers} =
      ToolResolver.resolve(agent, user_id, builtin_registry: Liteskill.BuiltinTools)

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

    state = %{
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
      log_fn: &Runs.add_log/5,
      cost_limit: Keyword.get(context, :cost_limit),
      config: agent.config || %{},
      prompt: handoff.prompt,
      prior_context: format_prior_context(handoff.prior_outputs),
      report_id: handoff[:report_id]
    }

    state =
      if resume_messages do
        Map.put(state, :resume_messages, resume_messages)
      else
        state
      end

    jido_agent = JidoAgent.new(state: state)

    log(run_id, "info", "llm_call", "Calling LLM for #{agent.name}", %{
      "agent" => agent.name,
      "model" => agent.llm_model.name
    })

    case LlmGenerate.run(%{}, %{state: jido_agent.state}) do
      {:ok, result} ->
        {:ok,
         %{analysis: result.analysis, output: result.output, messages: result[:messages] || []}}

      {:error, %{reason: reason, messages: messages}} ->
        {:error, "Agent '#{agent.name}' LLM call failed: #{reason}", messages}

      {:error, reason} ->
        {:error, "Agent '#{agent.name}' LLM call failed: #{inspect(reason)}", []}
    end
  end

  defp cost_limit_exceeded?(%{cost_limit: nil}), do: false

  defp cost_limit_exceeded?(%{cost_limit: cost_limit, id: run_id}) do
    case Liteskill.Usage.check_cost_limit(:run, run_id, cost_limit) do
      :ok -> false
      {:error, :cost_limit_exceeded, _} -> true
    end
  end

  defp format_prior_context([]), do: ""

  defp format_prior_context(outputs) do
    Enum.map_join(outputs, "\n\n", fn %{agent: name, role: role, output: summary} ->
      "--- #{name} (#{role}) ---\n#{summary}"
    end)
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

  defp format_stage_usage(nil), do: %{}

  defp format_stage_usage(usage) do
    %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cached_tokens" => usage.cached_tokens,
      "total_cost" => if(usage.total_cost, do: Decimal.to_string(usage.total_cost), else: "0"),
      "call_count" => usage.call_count
    }
  end

  defp log(run_id, level, step, message, metadata \\ %{}) do
    Runs.add_log(run_id, level, step, message, metadata)
  end
end
