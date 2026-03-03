defmodule Liteskill.Chat.Events.ConversationTruncated do
  @moduledoc """
  Event emitted when a conversation is truncated at a specific message.

  The target message and all messages after it are removed.
  """

  @derive Jason.Encoder
  defstruct [:message_id, :timestamp]
end
