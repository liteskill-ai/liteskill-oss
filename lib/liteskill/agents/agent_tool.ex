defmodule Liteskill.Agents.AgentTool do
  @moduledoc """
  Join table linking agent definitions to MCP server tools.

  Each record assigns one tool (identified by server + optional tool name) to an agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_tools" do
    field :tool_name, :string

    belongs_to :agent_definition, Liteskill.Agents.AgentDefinition
    belongs_to :mcp_server, Liteskill.McpServers.McpServer

    timestamps(type: :utc_datetime)
  end

  def changeset(agent_tool, attrs) do
    agent_tool
    |> cast(attrs, [:tool_name, :agent_definition_id, :mcp_server_id])
    |> validate_required([:agent_definition_id, :mcp_server_id])
    |> foreign_key_constraint(:agent_definition_id)
    |> foreign_key_constraint(:mcp_server_id)
    |> unique_constraint([:agent_definition_id, :mcp_server_id, :tool_name],
      name: :agent_tools_unique_idx
    )
  end
end
