defmodule Liteskill.Chat.Events.UserMessageAdded do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:message_id, :content, :timestamp, :tool_config]
end
