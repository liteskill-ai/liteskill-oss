defmodule Liteskill.LLM.SlowToolServer do
  @moduledoc """
  Test tool server that sleeps before responding, used to test tool execution timeouts.
  """

  def call_tool(_name, _input, _context) do
    Process.sleep(5_000)
    {:ok, %{"content" => [%{"text" => "slow result"}]}}
  end
end
