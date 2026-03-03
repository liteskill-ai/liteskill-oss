defmodule Liteskill.Chat.Events.AssistantStreamFailed do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:message_id, :error_type, :error_message, :retry_count, :timestamp]
end
