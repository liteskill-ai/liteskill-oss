defmodule Liteskill.Runs.ResumeHandler do
  @moduledoc """
  Handles crash recovery and pipeline resume logic for agent runs.

  Responsible for extracting handoff summaries between pipeline stages,
  finding crash messages for mid-agent resume, and detecting existing
  reports for pipeline-level resume.
  """

  @handoff_summary_max_chars 500

  @doc """
  Extracts a handoff summary from agent output.

  Looks for a `## Handoff Summary` section; falls back to the first
  #{@handoff_summary_max_chars} characters of the output.
  """
  def extract_handoff_summary(output) when is_binary(output) do
    case Regex.run(~r/##?\s*Handoff Summary\s*\n(.*?)(?:\n##|\z)/si, output) do
      [_, summary] -> summary |> String.trim() |> String.slice(0, @handoff_summary_max_chars)
      nil -> String.slice(output, 0, @handoff_summary_max_chars)
    end
  end

  def extract_handoff_summary(_), do: ""

  @doc """
  Finds the most recent handoff summary for an agent from run logs.

  Prefers stored `handoff_summary` metadata; falls back to extracting
  from the full output (backward compat with pre-migration logs).
  """
  def find_handoff_summary(logs, agent_name) do
    logs
    |> Enum.filter(fn log ->
      log.step == "agent_complete" && log.metadata["agent"] == agent_name
    end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
    |> case do
      nil ->
        nil

      log_entry ->
        log_entry.metadata["handoff_summary"] ||
          extract_handoff_summary(log_entry.metadata["output"])
    end
  end

  @doc """
  Finds crash messages for an agent from run logs (for mid-agent resume).
  """
  def find_crash_messages(logs, agent_name) do
    logs
    |> Enum.filter(fn log ->
      log.step == "agent_crash" && log.metadata["agent"] == agent_name
    end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
    |> case do
      nil -> nil
      log_entry -> log_entry.metadata["messages"]
    end
  end
end
