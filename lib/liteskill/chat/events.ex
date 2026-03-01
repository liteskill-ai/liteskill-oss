defmodule Liteskill.Chat.Events do
  @moduledoc """
  Event registry for chat domain events.

  Maps event_type strings to struct modules and handles serialization/deserialization.
  """

  alias Liteskill.Chat.Events.AssistantChunkReceived
  alias Liteskill.Chat.Events.AssistantStreamCompleted
  alias Liteskill.Chat.Events.AssistantStreamFailed
  alias Liteskill.Chat.Events.AssistantStreamStarted
  alias Liteskill.Chat.Events.ConversationArchived
  alias Liteskill.Chat.Events.ConversationCreated
  alias Liteskill.Chat.Events.ConversationForked
  alias Liteskill.Chat.Events.ConversationTitleUpdated
  alias Liteskill.Chat.Events.ConversationTruncated
  alias Liteskill.Chat.Events.ToolCallCompleted
  alias Liteskill.Chat.Events.ToolCallStarted
  alias Liteskill.Chat.Events.UserMessageAdded

  @event_types %{
    "ConversationCreated" => ConversationCreated,
    "UserMessageAdded" => UserMessageAdded,
    "AssistantStreamStarted" => AssistantStreamStarted,
    "AssistantChunkReceived" => AssistantChunkReceived,
    "AssistantStreamCompleted" => AssistantStreamCompleted,
    "AssistantStreamFailed" => AssistantStreamFailed,
    "ToolCallStarted" => ToolCallStarted,
    "ToolCallCompleted" => ToolCallCompleted,
    "ConversationForked" => ConversationForked,
    "ConversationTitleUpdated" => ConversationTitleUpdated,
    "ConversationArchived" => ConversationArchived,
    "ConversationTruncated" => ConversationTruncated
  }

  @event_types_reverse Map.new(@event_types, fn {k, v} -> {v, k} end)

  @doc """
  Converts an event struct to the event store format (map with :event_type, :data).
  """
  def serialize(%module{} = event) do
    event_type = Map.fetch!(@event_types_reverse, module)
    %{event_type: event_type, data: stringify_keys(Map.from_struct(event))}
  end

  @doc """
  Converts an event store Event record back to a domain event struct.
  """
  def deserialize(%{event_type: event_type, data: data}) do
    module = Map.fetch!(@event_types, event_type)
    struct(module, atomize_keys(data))
  end

  @doc """
  Returns the struct module for an event type string.
  """
  def module_for(event_type), do: Map.fetch!(@event_types, event_type)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> key
          end

        {atom_key, value}

      {key, value} when is_atom(key) ->
        {key, value}

      # coveralls-ignore-next-line
      {key, value} ->
        {key, value}
    end)
  end
end
