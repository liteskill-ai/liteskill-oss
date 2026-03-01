defmodule Liteskill.Chat.Events.AssistantStreamCompleted do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [
    :message_id,
    :full_content,
    :stop_reason,
    :input_tokens,
    :output_tokens,
    :latency_ms,
    :timestamp
  ]
end
