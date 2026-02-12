defmodule Liteskill.LLM.FakeToolServer do
  @moduledoc """
  Fake tool server for testing StreamHandler tool execution.

  Returns results from `Process.get(:fake_tool_results)` map keyed by tool name,
  or a default success response.
  """

  def call_tool(name, _input, _context) do
    results = Process.get(:fake_tool_results, %{})
    Map.get(results, name, {:ok, %{"content" => [%{"text" => "fake result for #{name}"}]}})
  end
end
