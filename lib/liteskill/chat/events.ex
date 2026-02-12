defmodule Liteskill.Chat.Events do
  @moduledoc """
  Event registry for chat domain events.

  Maps event_type strings to struct modules and handles serialization/deserialization.
  """

  alias Liteskill.Chat.Events.{
    ConversationCreated,
    UserMessageAdded,
    AssistantStreamStarted,
    AssistantChunkReceived,
    AssistantStreamCompleted,
    AssistantStreamFailed,
    ToolCallStarted,
    ToolCallCompleted,
    ConversationForked,
    ConversationTitleUpdated,
    ConversationArchived
  }

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
    "ConversationArchived" => ConversationArchived
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
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      # coveralls-ignore-next-line
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end
end
