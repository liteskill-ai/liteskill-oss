defmodule Liteskill.Agents do
  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Authorization,
      Liteskill.Rbac,
      Liteskill.McpServers,
      Liteskill.LLM,
      Liteskill.Usage,
      Liteskill.LlmModels
    ],
    exports: [AgentDefinition, AgentTool, ToolResolver, JidoAgent, Actions.LlmGenerate]

  @moduledoc """
  Context for managing agent definitions.

  Agent definitions are the "character sheets" for AI agents — name, backstory,
  opinions, strategy, model, and tool assignments. All operations are ACL-controlled.
  """

  alias Liteskill.Agents.{AgentDefinition, AgentTool}
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_agent(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "agents:create") do
      %AgentDefinition{}
      |> AgentDefinition.changeset(attrs)
      |> Authorization.create_with_owner_acl("agent_definition", [
        :llm_model,
        agent_tools: :mcp_server
      ])
    end
  end

  def update_agent(id, user_id, attrs) do
    case Repo.get(AgentDefinition, id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <- authorize_owner(agent, user_id) do
          agent
          |> AgentDefinition.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, [:llm_model, agent_tools: :mcp_server])}
            error -> error
          end
        end
    end
  end

  def delete_agent(id, user_id) do
    case Repo.get(AgentDefinition, id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <- authorize_owner(agent, user_id) do
          Repo.delete(agent)
        end
    end
  end

  # --- Queries ---

  def list_agents(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("agent_definition", user_id)

    AgentDefinition
    |> where([a], a.user_id == ^user_id or a.id in subquery(accessible_ids))
    |> order_by([a], asc: a.name)
    |> preload([:llm_model, agent_tools: :mcp_server])
    |> Repo.all()
  end

  def get_agent(id, user_id) do
    case Repo.get(AgentDefinition, id)
         |> Repo.preload(llm_model: :provider, agent_tools: :mcp_server) do
      nil ->
        {:error, :not_found}

      %AgentDefinition{user_id: ^user_id} = agent ->
        {:ok, agent}

      %AgentDefinition{} = agent ->
        if Authorization.has_access?("agent_definition", agent.id, user_id) do
          {:ok, agent}
        else
          {:error, :not_found}
        end
    end
  end

  def get_agent!(id) do
    Repo.get!(AgentDefinition, id) |> Repo.preload(llm_model: :provider, agent_tools: :mcp_server)
  end

  # --- Tool Management ---

  def add_tool(agent_definition_id, mcp_server_id, tool_name \\ nil, user_id) do
    case Repo.get(AgentDefinition, agent_definition_id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, _agent} <- authorize_owner(agent, user_id) do
          %AgentTool{}
          |> AgentTool.changeset(%{
            agent_definition_id: agent_definition_id,
            mcp_server_id: mcp_server_id,
            tool_name: tool_name
          })
          |> Repo.insert()
        end
    end
  end

  def remove_tool(agent_definition_id, mcp_server_id, tool_name \\ nil, user_id) do
    case Repo.get(AgentDefinition, agent_definition_id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, _agent} <- authorize_owner(agent, user_id) do
          query =
            from(at in AgentTool,
              where:
                at.agent_definition_id == ^agent_definition_id and
                  at.mcp_server_id == ^mcp_server_id
            )

          query =
            if tool_name do
              where(query, [at], at.tool_name == ^tool_name)
            else
              where(query, [at], is_nil(at.tool_name))
            end

          case Repo.one(query) do
            nil -> {:error, :not_found}
            tool -> Repo.delete(tool)
          end
        end
    end
  end

  def list_tools(agent_definition_id) do
    AgentTool
    |> where([at], at.agent_definition_id == ^agent_definition_id)
    |> preload(:mcp_server)
    |> Repo.all()
  end

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
