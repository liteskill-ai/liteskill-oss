defmodule Liteskill.Agents.JidoAgent do
  @moduledoc """
  Generic Jido Agent used to execute Liteskill AgentDefinitions.

  All AgentDefinitions share this single Jido agent module — they differ only
  in their runtime state (prompt, system_prompt, model, tools, etc.), not in
  structure.
  """

  use Jido.Agent,
    name: "liteskill_agent",
    description: "Liteskill agent that delegates to LLM via ReqLLM",
    schema: [
      agent_name: [type: :string, default: ""],
      system_prompt: [type: :string, default: ""],
      backstory: [type: :string, default: ""],
      opinions: [type: :any, default: %{}],
      role: [type: :string, default: "worker"],
      strategy: [type: :string, default: "direct"],
      llm_model: [type: :any, default: nil],
      tools: [type: {:list, :any}, default: []],
      tool_servers: [type: :any, default: %{}],
      user_id: [type: :any, default: nil],
      run_id: [type: :any, default: nil],
      cost_limit: [type: :any, default: nil],
      config: [type: :any, default: %{}],
      prompt: [type: :string, default: ""],
      prior_context: [type: :string, default: ""],
      report_id: [type: :string, default: nil],
      analysis: [type: :string, default: ""],
      output: [type: :string, default: ""]
    ]
end
