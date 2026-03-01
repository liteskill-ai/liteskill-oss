defmodule Liteskill.Chat.Events.AssistantStreamStarted do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:message_id, :model_id, :request_id, :timestamp, :rag_sources]
end
