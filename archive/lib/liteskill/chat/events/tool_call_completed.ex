defmodule Liteskill.Chat.Events.ToolCallCompleted do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:message_id, :tool_use_id, :tool_name, :input, :output, :duration_ms, :timestamp]
end
