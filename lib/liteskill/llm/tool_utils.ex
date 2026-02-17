defmodule Liteskill.LLM.ToolUtils do
  @moduledoc """
  Shared utilities for tool calling used by both `StreamHandler` (streaming)
  and `LlmGenerate` (synchronous agent pipeline).

  Centralises tool spec conversion, tool output formatting, and
  tool execution dispatch so both code paths stay in sync.
  """

  alias Liteskill.McpServers.Client, as: McpClient

  @doc """
  Converts a Bedrock-format tool spec map to a `ReqLLM.tool` struct.
  """
  def convert_tool(%{"toolSpec" => spec}) do
    ReqLLM.tool(
      name: spec["name"],
      description: spec["description"] || "",
      parameter_schema: get_in(spec, ["inputSchema", "json"]) || %{},
      # coveralls-ignore-next-line
      callback: fn _args -> {:ok, nil} end
    )
  end

  @doc """
  Formats tool execution output into a string for inclusion in
  conversation messages or LLM context.
  """
  def format_tool_output({:ok, %{"content" => content}}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  def format_tool_output({:ok, data}) when is_map(data), do: Jason.encode!(data)
  def format_tool_output({:ok, data}), do: inspect(data)
  def format_tool_output({:error, _}), do: "Error: tool execution failed"

  @doc """
  Dispatches a tool call to the appropriate server.

  - `%{builtin: module}` — calls `module.call_tool/3`
  - MCP server struct — calls `McpClient.call_tool/4`
  - `nil` — returns `{:error, "No server configured for tool <name>"}`
  """
  def execute_tool(%{builtin: module}, tool_name, input, opts) do
    context = Keyword.take(opts, [:user_id])
    module.call_tool(tool_name, input, context)
  end

  def execute_tool(server, tool_name, input, opts) when not is_nil(server) do
    req_opts = Keyword.take(opts, [:plug])
    McpClient.call_tool(server, tool_name, input, req_opts)
  end

  def execute_tool(nil, tool_name, _input, _opts) do
    {:error, "No server configured for tool #{tool_name}"}
  end
end
