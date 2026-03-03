defmodule Liteskill.Chat.Events.ConversationForked do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:new_conversation_id, :parent_stream_id, :fork_at_version, :user_id, :timestamp]
end
