defmodule Liteskill.Agents do
  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Authorization,
      Liteskill.Rbac,
      Liteskill.McpServers,
      Liteskill.LLM,
      Liteskill.LlmGateway,
      Liteskill.Usage,
      Liteskill.LlmModels,
      Liteskill.Rag,
      Liteskill.DataSources,
      Liteskill.Retry
    ],
    exports: [AgentDefinition, ToolResolver, JidoAgent, Actions.LlmGenerate]

  @moduledoc """
  Context for managing agent definitions.

  Agent definitions are the "character sheets" for AI agents — name, backstory,
  opinions, strategy, model, and tool/datasource access via ACLs.
  All operations are ACL-controlled.
  """

  alias Liteskill.Agents.AgentDefinition
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_agent(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]
    role_id = attrs[:role_id] || attrs["role_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "agents:create"),
         :ok <- validate_model_access(attrs[:llm_model_id] || attrs["llm_model_id"], user_id) do
      result =
        %AgentDefinition{}
        |> AgentDefinition.changeset(attrs)
        |> Authorization.create_with_owner_acl("agent_definition", [:llm_model])

      with {:ok, agent} <- result do
        sync_agent_role(agent.id, role_id)
        {:ok, agent}
      end
    end
  end

  def update_agent(id, user_id, attrs) do
    role_id = attrs[:role_id] || attrs["role_id"]

    case Repo.get(AgentDefinition, id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <- authorize_owner(agent, user_id),
             :ok <- validate_model_access(attrs[:llm_model_id] || attrs["llm_model_id"], user_id) do
          agent
          |> AgentDefinition.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              sync_agent_role(updated.id, role_id)
              {:ok, Repo.preload(updated, [:llm_model])}

            error ->
              error
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
    |> limit(1000)
    |> preload([:llm_model])
    |> Repo.all()
  end

  def get_agent(id, user_id) do
    case Repo.get(AgentDefinition, id)
         |> Repo.preload(llm_model: :provider) do
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
    Repo.get!(AgentDefinition, id) |> Repo.preload(llm_model: :provider)
  end

  # --- Agent Resource Access (Tools) ---

  @doc "Grants an agent access to an MCP server."
  def grant_tool_access(agent_definition_id, mcp_server_id, user_id) do
    with {:ok, agent} <- get_and_authorize_owner(agent_definition_id, user_id),
         :ok <- verify_entity_exists(Liteskill.McpServers.McpServer, mcp_server_id) do
      Authorization.grant_agent_access("mcp_server", mcp_server_id, agent.id)
    end
  end

  @doc "Revokes an agent's access to an MCP server."
  def revoke_tool_access(agent_definition_id, mcp_server_id, user_id) do
    with {:ok, agent} <- get_and_authorize_owner(agent_definition_id, user_id) do
      Authorization.revoke_agent_access("mcp_server", mcp_server_id, agent.id)
    end
  end

  @doc "Lists MCP server IDs accessible to an agent."
  def list_tool_server_ids(agent_definition_id) do
    Authorization.agent_accessible_entity_ids("mcp_server", agent_definition_id)
    |> Repo.all()
  end

  @doc "Lists MCP servers accessible to an agent (full structs)."
  def list_accessible_servers(agent_definition_id) do
    server_ids = list_tool_server_ids(agent_definition_id)

    Liteskill.McpServers.McpServer
    |> where([s], s.id in ^server_ids)
    |> order_by([s], asc: s.name)
    |> limit(1000)
    |> Repo.all()
  end

  # --- Agent Resource Access (Data Sources) ---

  @doc "Grants an agent access to a data source."
  def grant_source_access(agent_definition_id, source_id, user_id) do
    with {:ok, agent} <- get_and_authorize_owner(agent_definition_id, user_id),
         :ok <- verify_entity_exists(Liteskill.DataSources.Source, source_id) do
      Authorization.grant_agent_access("source", source_id, agent.id)
    end
  end

  @doc "Revokes an agent's access to a data source."
  def revoke_source_access(agent_definition_id, source_id, user_id) do
    with {:ok, agent} <- get_and_authorize_owner(agent_definition_id, user_id) do
      Authorization.revoke_agent_access("source", source_id, agent.id)
    end
  end

  @doc "Lists data source IDs accessible to an agent."
  def list_source_ids(agent_definition_id) do
    Authorization.agent_accessible_entity_ids("source", agent_definition_id)
    |> Repo.all()
  end

  # --- Private ---

  defp get_and_authorize_owner(agent_definition_id, user_id) do
    case Repo.get(AgentDefinition, agent_definition_id) do
      nil -> {:error, :not_found}
      agent -> authorize_owner(agent, user_id)
    end
  end

  defp verify_entity_exists(schema, id) do
    case Repo.get(schema, id) do
      nil -> {:error, :not_found}
      _ -> :ok
    end
  end

  defp sync_agent_role(agent_definition_id, role_id) do
    current_roles = Liteskill.Rbac.list_agent_roles(agent_definition_id)

    for role <- current_roles do
      Liteskill.Rbac.remove_role_from_agent(agent_definition_id, role.id)
    end

    if role_id && role_id != "" do
      Liteskill.Rbac.assign_role_to_agent(agent_definition_id, role_id)
    end
  end

  defdelegate authorize_owner(entity, user_id), to: Authorization

  defp validate_model_access(nil, _user_id), do: :ok
  defp validate_model_access("", _user_id), do: :ok

  defp validate_model_access(model_id, user_id) do
    case Liteskill.LlmModels.get_model(model_id, user_id) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_model}
    end
  end
end
