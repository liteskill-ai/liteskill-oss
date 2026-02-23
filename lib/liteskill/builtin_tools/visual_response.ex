defmodule Liteskill.BuiltinTools.VisualResponse do
  @moduledoc """
  Built-in tool suite for generating visual UI responses.

  Provides a tool that returns the json-render component catalog and prompt
  instructions, allowing the AI to render interactive visual elements (cards,
  metrics, charts, tables, etc.) inline in chat messages.

  The system prompt is generated at build time from the JS catalog
  (`assets/js/json-render/catalog.js`) via `catalog.prompt()`, keeping the
  JS component definitions as the single source of truth.
  """

  @behaviour Liteskill.BuiltinTools

  @prompt_file "priv/json_render_prompt.txt"
  @external_resource @prompt_file
  @json_render_prompt (case File.read(@prompt_file) do
                         {:ok, content} ->
                           content

                         {:error, _} ->
                           # Fallback for first-time checkout before `mix gen.jr_prompt`
                           "Visual response catalog not yet generated. Run `mix gen.jr_prompt` first."
                       end)

  @impl true
  def id, do: "visual"

  @impl true
  def name, do: "Visual Responses"

  @impl true
  def description, do: "Generate interactive visual UI responses"

  @impl true
  def list_tools do
    [
      %{
        "name" => "visual__get_catalog",
        "description" =>
          "Get the visual component catalog for rendering interactive UI inline in the conversation. " <>
            "Call this FIRST when the user's request would benefit from a visual response " <>
            "(dashboards, data displays, charts, structured layouts, status overviews). " <>
            "Returns component schemas, format instructions, and output examples. " <>
            "Supports: Card, Metric, Table, BarChart, LineChart, PieChart, List, Alert, " <>
            "Progress, Badge, Stack, Grid, Button — with state, visibility, dynamic props, and events.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      }
    ]
  end

  @impl true
  def call_tool("visual__get_catalog", _input, _context) do
    {:ok, @json_render_prompt}
    |> wrap_result()
  end

  def call_tool(tool_name, _input, _context) do
    {:error, "Unknown tool: #{tool_name}"}
    |> wrap_result()
  end

  defp wrap_result({:ok, text}) when is_binary(text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp wrap_result({:error, reason}) when is_binary(reason) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(%{"error" => reason})}]}}
  end
end
