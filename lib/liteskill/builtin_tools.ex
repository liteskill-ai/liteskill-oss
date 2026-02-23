defmodule Liteskill.BuiltinTools do
  use Boundary,
    top_level?: true,
    check: [out: false],
    deps: [],
    exports: [Reports, Wiki, AgentStudio, DeepResearch]

  @moduledoc """
  Behaviour and registry for built-in tool suites.

  Built-in tools are tool suites that run in-process (no HTTP),
  appearing alongside MCP servers in the tool picker.
  """

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback list_tools() :: [map()]
  @callback call_tool(tool_name :: String.t(), input :: map(), context :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @registry [
    Liteskill.BuiltinTools.Reports,
    Liteskill.BuiltinTools.Wiki,
    Liteskill.BuiltinTools.AgentStudio,
    Liteskill.BuiltinTools.DeepResearch,
    Liteskill.BuiltinTools.VisualResponse
  ]

  def all, do: @registry

  @doc """
  Returns a flat list of tool maps for all built-in suites,
  formatted the same as MCP tool entries in available_tools.
  """
  def all_tools do
    Enum.flat_map(@registry, fn mod ->
      server_id = "builtin:#{mod.id()}"
      server_name = mod.name()

      Enum.map(mod.list_tools(), fn tool ->
        %{
          id: "#{server_id}:#{tool["name"]}",
          server_id: server_id,
          server_name: server_name,
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"]
        }
      end)
    end)
  end

  @doc """
  Returns virtual server maps for all built-in suites.
  These can be shown alongside real MCP servers in the UI.
  """
  def virtual_servers do
    Enum.map(@registry, fn mod ->
      %{
        id: "builtin:#{mod.id()}",
        name: mod.name(),
        description: mod.description(),
        url: nil,
        api_key: nil,
        headers: %{},
        status: "active",
        global: true,
        user_id: nil,
        builtin: mod,
        inserted_at: nil,
        updated_at: nil
      }
    end)
  end

  @doc """
  Finds the built-in module that handles the given tool name, or nil.
  """
  def find_handler(tool_name) do
    Enum.find(@registry, fn mod ->
      Enum.any?(mod.list_tools(), &(&1["name"] == tool_name))
    end)
  end
end
