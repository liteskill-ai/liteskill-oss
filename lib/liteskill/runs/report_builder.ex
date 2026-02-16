defmodule Liteskill.Runs.ReportBuilder do
  @moduledoc """
  Builds and writes report content for agent pipeline runs.

  Handles report creation, section writing, and all content generation
  (overview, agent config, synthesis, conclusion).
  """

  alias Liteskill.BuiltinTools.Reports, as: ReportsTools
  alias Liteskill.Runs

  def get_or_create_report(run, agents, context) do
    case find_existing_report(run) do
      nil ->
        title = build_report_title(run, agents)

        with {:ok, %{"content" => [%{"text" => json}]}} <-
               ReportsTools.call_tool("reports__create", %{"title" => title}, context),
             %{"id" => report_id} <- Jason.decode!(json) do
          Runs.add_log(run.id, "info", "create_report", "Created report", %{
            "report_id" => report_id
          })

          {:ok, report_id}
        else
          error -> {:error, error}
        end

      report_id ->
        Runs.add_log(run.id, "info", "resume", "Resuming with existing report", %{
          "report_id" => report_id
        })

        {:ok, report_id}
    end
  end

  def find_existing_report(run) do
    run.deliverables["report_id"] ||
      run.run_logs
      |> Enum.find(&(&1.step == "create_report"))
      |> case do
        nil -> nil
        log_entry -> log_entry.metadata["report_id"]
      end
  end

  def write_sections(report_id, sections, context) do
    case ReportsTools.call_tool(
           "reports__modify_sections",
           %{"report_id" => report_id, "actions" => sections},
           context
         ) do
      {:ok, %{"content" => _}} ->
        :ok

      # coveralls-ignore-start
      error ->
        error
        # coveralls-ignore-stop
    end
  end

  def section(path, content), do: %{"action" => "upsert", "path" => path, "content" => content}

  def build_report_title(run, agents) do
    agent_names = Enum.map_join(agents, ", ", fn {agent, _} -> agent.name end)
    "#{run.name} — #{agent_names}"
  end

  def overview_content(run, agents) do
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

  def synthesis_content(run, agents, final_context) do
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

  def conclusion_content(run, agents) do
    "Run **#{run.name}** completed successfully through a " <>
      "**#{length(agents)}-agent pipeline**. " <>
      "Each agent contributed their specialized analysis, " <>
      "producing a comprehensive deliverable. " <>
      "This report was generated automatically by the Agent Studio runner."
  end

  def agent_config_content(agent) do
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
end
