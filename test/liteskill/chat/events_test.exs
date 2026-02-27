defmodule Liteskill.Chat.EventsTest do
  use ExUnit.Case, async: true

  alias Liteskill.Chat.Events
  alias Liteskill.Chat.Events.{ConversationCreated, UserMessageAdded, ConversationArchived}

  describe "serialize/1" do
    test "converts a ConversationCreated struct to event store format" do
      event = %ConversationCreated{
        conversation_id: "c1",
        user_id: "u1",
        title: "Test",
        model_id: "claude",
        system_prompt: nil
      }

      result = Events.serialize(event)
      assert result.event_type == "ConversationCreated"
      assert result.data["conversation_id"] == "c1"
      assert result.data["user_id"] == "u1"
      assert is_binary(Map.keys(result.data) |> Enum.at(0))
    end

    test "converts a ConversationArchived struct" do
      event = %ConversationArchived{timestamp: "2024-01-01T00:00:00Z"}
      result = Events.serialize(event)
      assert result.event_type == "ConversationArchived"
      assert result.data["timestamp"] == "2024-01-01T00:00:00Z"
    end
  end

  describe "deserialize/1" do
    test "converts event store format back to struct" do
      event = %{
        event_type: "UserMessageAdded",
        data: %{"message_id" => "m1", "content" => "hello", "timestamp" => "now"}
      }

      result = Events.deserialize(event)
      assert %UserMessageAdded{} = result
      assert result.message_id == "m1"
      assert result.content == "hello"
    end

    test "handles atom keys in data" do
      event = %{
        event_type: "ConversationArchived",
        data: %{timestamp: "now"}
      }

      result = Events.deserialize(event)
      assert %ConversationArchived{} = result
      assert result.timestamp == "now"
    end

    test "tolerates extra unknown fields in event data without crashing" do
      # Simulates schema evolution: an old event has a field that no longer
      # exists in the struct. deserialize must not crash.
      event = %{
        event_type: "UserMessageAdded",
        data: %{
          "message_id" => "m1",
          "content" => "hello",
          "timestamp" => "now",
          "removed_field_from_v1" => "legacy_value"
        }
      }

      result = Events.deserialize(event)
      assert %UserMessageAdded{} = result
      assert result.message_id == "m1"
      assert result.content == "hello"
    end

    test "round-trips through serialize then deserialize" do
      original = %ConversationCreated{
        conversation_id: "c1",
        user_id: "u1",
        title: "Test",
        model_id: "claude",
        system_prompt: "Be helpful",
        llm_model_id: "model-123"
      }

      round_tripped =
        original
        |> Events.serialize()
        |> Events.deserialize()

      assert round_tripped.conversation_id == original.conversation_id
      assert round_tripped.user_id == original.user_id
      assert round_tripped.title == original.title
      assert round_tripped.model_id == original.model_id
      assert round_tripped.system_prompt == original.system_prompt
      assert round_tripped.llm_model_id == original.llm_model_id
    end
  end

  describe "module_for/1" do
    test "returns the module for a known event type" do
      assert Events.module_for("ConversationCreated") == ConversationCreated
      assert Events.module_for("UserMessageAdded") == UserMessageAdded
    end

    test "raises for unknown event type" do
      assert_raise KeyError, fn ->
        Events.module_for("UnknownEvent")
      end
    end
  end
end
