defmodule Liteskill.Chat.Events.ConversationTitleUpdated do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:title, :timestamp]
end
