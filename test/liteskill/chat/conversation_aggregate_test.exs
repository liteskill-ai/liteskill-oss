defmodule Liteskill.Chat.ConversationAggregateTest do
  use ExUnit.Case, async: true

  alias Liteskill.Chat.ConversationAggregate

  describe "init/0" do
    test "returns initial state with :created status" do
      state = ConversationAggregate.init()
      assert state.status == :created
      assert state.messages == []
      assert state.current_stream == nil
      assert state.conversation_id == nil
    end
  end

  describe "create_conversation" do
    test "transitions from :created to :active" do
      state = ConversationAggregate.init()

      {:ok, events} =
        ConversationAggregate.handle_command(state, {:create_conversation, create_params()})

      assert length(events) == 1
      assert Enum.at(events, 0).event_type == "ConversationCreated"

      new_state = apply_events(state, events)
      assert new_state.status == :active
      assert new_state.conversation_id == "conv-1"
      assert new_state.user_id == "user-1"
      assert new_state.title == "Test"
      assert new_state.model_id == "claude"
    end

    test "cannot create conversation twice" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :already_created} =
               ConversationAggregate.handle_command(
                 state,
                 {:create_conversation, create_params()}
               )
    end
  end

  describe "add_user_message" do
    test "works in :active state" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      {:ok, events} =
        ConversationAggregate.handle_command(state, {:add_user_message, %{content: "hello"}})

      new_state = apply_events(state, events)
      assert length(new_state.messages) == 1
      assert hd(new_state.messages).role == "user"
      assert hd(new_state.messages).content == "hello"
    end

    test "cannot add message when archived" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert {:error, :conversation_archived} =
               ConversationAggregate.handle_command(state, {:add_user_message, %{content: "hi"}})
    end

    test "cannot add message when streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:start_assistant_stream, %{model_id: "claude"}}
        ])

      assert {:error, :currently_streaming} =
               ConversationAggregate.handle_command(state, {:add_user_message, %{content: "hi"}})
    end

    test "includes tool_config in event and state" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      tool_config = %{
        "servers" => [%{"id" => "srv-1", "name" => "TestServer"}],
        "tools" => [%{"toolSpec" => %{"name" => "my-tool"}}],
        "auto_confirm" => true
      }

      {:ok, events} =
        ConversationAggregate.handle_command(
          state,
          {:add_user_message, %{content: "hello", tool_config: tool_config}}
        )

      [event] = events
      assert event.data["tool_config"] == tool_config

      new_state = apply_events(state, events)
      assert hd(new_state.messages).tool_config == tool_config
    end
  end

  describe "start_assistant_stream" do
    test "transitions to :streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      state = apply_commands(state, [{:start_assistant_stream, %{model_id: "claude"}}])
      assert state.status == :streaming
      assert state.current_stream != nil
      assert state.current_stream.model_id == "claude"
      assert state.current_stream.chunks == []
      assert state.current_stream.tool_calls == []
    end

    test "cannot start stream when already streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:start_assistant_stream, %{model_id: "claude"}}
        ])

      assert {:error, :already_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:start_assistant_stream, %{model_id: "claude"}}
               )
    end

    test "cannot start stream when archived" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert {:error, :conversation_archived} =
               ConversationAggregate.handle_command(
                 state,
                 {:start_assistant_stream, %{model_id: "claude"}}
               )
    end
  end

  describe "receive_chunk" do
    test "appends chunk when streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:start_assistant_stream, %{model_id: "claude"}}
        ])

      state =
        apply_commands(state, [
          {:receive_chunk,
           %{message_id: state.current_stream.message_id, chunk_index: 0, delta_text: "Hello"}}
        ])

      assert length(state.current_stream.chunks) == 1
      assert hd(state.current_stream.chunks).delta_text == "Hello"
    end

    test "cannot receive chunk when not streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:receive_chunk, %{message_id: "m1", chunk_index: 0, delta_text: "x"}}
               )
    end
  end

  describe "complete_stream" do
    test "transitions back to :active and adds assistant message" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:add_user_message, %{content: "hello"}},
          {:start_assistant_stream, %{model_id: "claude"}},
          {:receive_chunk, %{message_id: "m1", chunk_index: 0, delta_text: "Hello"}}
        ])

      # Use the actual message_id from the current_stream
      msg_id = state.current_stream.message_id

      state =
        apply_commands(state, [
          {:complete_stream,
           %{
             message_id: msg_id,
             full_content: "Hello there!",
             input_tokens: 10,
             output_tokens: 5
           }}
        ])

      assert state.status == :active
      assert state.current_stream == nil
      assert length(state.messages) == 2
      # Messages are prepended, so newest is first
      assistant_msg = hd(state.messages)
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "Hello there!"
    end

    test "cannot complete when not streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:complete_stream, %{message_id: "m1", full_content: "x"}}
               )
    end
  end

  describe "fail_stream" do
    test "transitions back to :active" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:start_assistant_stream, %{model_id: "claude"}}
        ])

      state =
        apply_commands(state, [
          {:fail_stream,
           %{
             message_id: state.current_stream.message_id,
             error_type: "rate_limit",
             error_message: "429 Too Many Requests"
           }}
        ])

      assert state.status == :active
      assert state.current_stream == nil
    end

    test "cannot fail when not streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:fail_stream, %{message_id: "m1", error_type: "err", error_message: "msg"}}
               )
    end
  end

  describe "tool_call lifecycle" do
    test "start and complete tool call while streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:start_assistant_stream, %{model_id: "claude"}}
        ])

      state =
        apply_commands(state, [
          {:start_tool_call,
           %{
             message_id: state.current_stream.message_id,
             tool_use_id: "tool-1",
             tool_name: "calculator"
           }}
        ])

      assert length(state.current_stream.tool_calls) == 1
      assert hd(state.current_stream.tool_calls).status == :started

      state =
        apply_commands(state, [
          {:complete_tool_call,
           %{
             message_id: state.current_stream.message_id,
             tool_use_id: "tool-1",
             tool_name: "calculator",
             input: %{"expr" => "2+2"},
             output: %{"result" => 4},
             duration_ms: 50
           }}
        ])

      assert hd(state.current_stream.tool_calls).status == :completed
    end

    test "cannot start tool call when not streaming" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:start_tool_call, %{message_id: "m1", tool_use_id: "t1", tool_name: "calc"}}
               )
    end

    test "cannot complete tool call when archived" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:complete_tool_call, %{message_id: "m1", tool_use_id: "t1", tool_name: "calc"}}
               )
    end

    test "cannot complete tool call in active state" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      assert {:error, :not_streaming} =
               ConversationAggregate.handle_command(
                 state,
                 {:complete_tool_call, %{message_id: "m1", tool_use_id: "t1", tool_name: "calc"}}
               )
    end
  end

  describe "update_title" do
    test "updates the title" do
      state =
        apply_commands(ConversationAggregate.init(), [{:create_conversation, create_params()}])

      state = apply_commands(state, [{:update_title, %{title: "New Title"}}])
      assert state.title == "New Title"
    end

    test "cannot update title when archived" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert {:error, :conversation_archived} =
               ConversationAggregate.handle_command(
                 state,
                 {:update_title, %{title: "Nope"}}
               )
    end
  end

  describe "archive" do
    test "transitions to :archived" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert state.status == :archived
    end

    test "cannot archive twice" do
      state =
        apply_commands(ConversationAggregate.init(), [
          {:create_conversation, create_params()},
          {:archive, %{}}
        ])

      assert {:error, :already_archived} =
               ConversationAggregate.handle_command(state, {:archive, %{}})
    end
  end

  describe "apply_event for ToolCallCompleted with nil current_stream" do
    test "preserves state without updating tool calls" do
      state = %ConversationAggregate{status: :active, current_stream: nil}

      new_state =
        ConversationAggregate.apply_event(state, %{
          event_type: "ToolCallCompleted",
          data: %{
            "tool_use_id" => "tool-1",
            "tool_name" => "calculator",
            "input" => %{"expr" => "1+1"},
            "output" => %{"result" => 2},
            "duration_ms" => 10
          }
        })

      assert new_state.current_stream == nil
    end
  end

  describe "apply_event for ConversationForked" do
    test "sets parent_stream_id and fork_at_version" do
      state = %ConversationAggregate{status: :active}

      new_state =
        ConversationAggregate.apply_event(state, %{
          event_type: "ConversationForked",
          data: %{
            "parent_stream_id" => "conversation-parent",
            "fork_at_version" => 3
          }
        })

      assert new_state.parent_stream_id == "conversation-parent"
      assert new_state.fork_at_version == 3
    end
  end

  defp create_params do
    %{conversation_id: "conv-1", user_id: "user-1", title: "Test", model_id: "claude"}
  end

  defp apply_commands(state, commands) do
    Enum.reduce(commands, state, fn command, acc ->
      {:ok, events} = ConversationAggregate.handle_command(acc, command)
      apply_events(acc, events)
    end)
  end

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn event_data, acc ->
      event = %{event_type: event_data.event_type, data: stringify_keys(event_data.data)}
      ConversationAggregate.apply_event(acc, event)
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
