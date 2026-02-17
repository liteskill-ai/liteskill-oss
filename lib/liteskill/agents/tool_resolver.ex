defmodule Liteskill.Agents.ToolResolver do
  @moduledoc """
  Resolves an AgentDefinition's assigned tools (agent_tools + builtin_server_ids)
  into tool specs and server maps for LLM tool calling.
  """

  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient

  require Logger

  @doc """
  Resolves all tools for an agent definition.

  Returns `{tools, tool_servers}` where:
  - `tools` is a list of Bedrock-format tool specs
  - `tool_servers` is a map of `tool_name => server` for execution routing

  `opts`:
  - `:builtin_registry` — module implementing `all/0`
  """
  def resolve(agent, user_id, opts \\ []) do
    {mcp_tools, mcp_servers} = resolve_mcp_tools(agent, user_id)
    builtin_registry = opts[:builtin_registry]
    {builtin_tools, builtin_servers} = resolve_builtin_tools(agent, builtin_registry)

    {mcp_tools ++ builtin_tools, Map.merge(mcp_servers, builtin_servers)}
  end

  defp resolve_mcp_tools(agent, user_id) do
    agent.agent_tools
    |> Enum.reduce({[], %{}}, fn agent_tool, {tools_acc, servers_acc} ->
      server = agent_tool.mcp_server

      if server do
        resolve_server_tools(agent_tool, server, user_id, {tools_acc, servers_acc})
      else
        # coveralls-ignore-next-line
        Logger.warning("AgentTool #{agent_tool.id} has no preloaded mcp_server, skipping")
        {tools_acc, servers_acc}
      end
    end)
  end

  # coveralls-ignore-start
  defp resolve_server_tools(agent_tool, server, user_id, {tools_acc, servers_acc}) do
    case McpClient.list_tools(server) do
      {:ok, tool_list} ->
        filtered =
          if agent_tool.tool_name do
            Enum.filter(tool_list, &(&1["name"] == agent_tool.tool_name))
          else
            tool_list
          end

        new_tools = Enum.map(filtered, &to_bedrock_spec/1)

        new_servers =
          Map.new(filtered, fn tool ->
            resolved_server =
              case McpServers.get_server(server.id, user_id) do
                {:ok, s} -> s
                _ -> server
              end

            {tool["name"], resolved_server}
          end)

        {tools_acc ++ new_tools, Map.merge(servers_acc, new_servers)}

      {:error, reason} ->
        Logger.warning("Failed to fetch tools from #{server.name}: #{inspect(reason)}, skipping")

        {tools_acc, servers_acc}
    end
  end

  # coveralls-ignore-stop

  defp resolve_builtin_tools(_agent, nil), do: {[], %{}}

  defp resolve_builtin_tools(agent, builtin_registry) do
    builtin_ids = get_in(agent.config, ["builtin_server_ids"]) || []

    if builtin_ids == [] do
      {[], %{}}
    else
      all_builtins = builtin_registry.all()

      Enum.reduce(builtin_ids, {[], %{}}, fn builtin_id, {tools_acc, servers_acc} ->
        case find_builtin_module(builtin_id, all_builtins) do
          nil ->
            Logger.warning("Unknown builtin server ID: #{builtin_id}, skipping")
            {tools_acc, servers_acc}

          module ->
            tool_list = module.list_tools()
            new_tools = Enum.map(tool_list, &to_bedrock_spec/1)

            virtual_server = %{
              builtin: module,
              id: builtin_id,
              name: module.name()
            }

            new_servers = Map.new(tool_list, fn tool -> {tool["name"], virtual_server} end)

            {tools_acc ++ new_tools, Map.merge(servers_acc, new_servers)}
        end
      end)
    end
  end

  defp find_builtin_module(builtin_id, builtins) do
    Enum.find(builtins, fn mod ->
      "builtin:#{mod.id()}" == builtin_id
    end)
  end

  defp to_bedrock_spec(tool) do
    %{
      "toolSpec" => %{
        "name" => tool["name"],
        "description" => tool["description"] || "",
        "inputSchema" => %{"json" => tool["inputSchema"] || %{}}
      }
    }
  end
end
