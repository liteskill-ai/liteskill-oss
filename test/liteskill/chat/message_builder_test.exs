defmodule Liteskill.Chat.MessageBuilderTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat
  alias Liteskill.Chat.MessageBuilder

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "builder-test-#{System.unique_integer([:positive])}@example.com",
        name: "Builder Tester",
        oidc_sub: "builder-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "build_llm_messages/1" do
    test "converts user and assistant messages to LLM format", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Builder Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      assert [%{"role" => "user", "content" => [%{"text" => "Hello"}]}] = result
    end

    test "filters out non-complete messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Filter Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      # Start a streaming message (will be status "streaming", not "complete")
      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()

      command =
        {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}

      {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
      Projector.project_events(conv.stream_id, events)

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      # Only the user message should appear (streaming message filtered out)
      assert length(result) == 1
      assert hd(result)["role"] == "user"
    end

    test "filters out empty user messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Empty Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)

      # Simulate empty message by updating
      msg = hd(messages)
      msg |> Liteskill.Chat.Message.changeset(%{content: ""}) |> Repo.update!()

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      assert result == []
    end

    test "builds assistant messages with tool_use and tool results", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Tool Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Use a tool")

      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()
      tool_use_id = "tool-#{System.unique_integer([:positive])}"

      # Start assistant stream
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
        )

      Projector.project_events(conv.stream_id, events)

      # Start tool call
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_tool_call,
           %{
             message_id: message_id,
             tool_use_id: tool_use_id,
             tool_name: "test_tool",
             input: %{"key" => "value"}
           }}
        )

      Projector.project_events(conv.stream_id, events)

      # Complete tool call
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_tool_call,
           %{
             message_id: message_id,
             tool_use_id: tool_use_id,
             tool_name: "test_tool",
             input: %{"key" => "value"},
             output: %{"content" => [%{"text" => "tool result"}]},
             duration_ms: 100
           }}
        )

      Projector.project_events(conv.stream_id, events)

      # Complete stream with tool_use stop_reason
      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_stream,
           %{
             message_id: message_id,
             full_content: "Let me use a tool",
             stop_reason: "tool_use",
             latency_ms: 500
           }}
        )

      Projector.project_events(conv.stream_id, events)

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      # Should have: user msg, assistant msg with toolUse, user msg with toolResult
      assert length(result) == 3

      assistant_msg = Enum.at(result, 1)
      assert assistant_msg["role"] == "assistant"

      tool_use_block = Enum.find(assistant_msg["content"], &Map.has_key?(&1, "toolUse"))
      assert tool_use_block["toolUse"]["name"] == "test_tool"

      tool_result_msg = Enum.at(result, 2)
      assert tool_result_msg["role"] == "user"
      tool_result = hd(tool_result_msg["content"])
      assert tool_result["toolResult"]["toolUseId"] == tool_use_id
    end

    test "merges consecutive same-role messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Merge Test"})
      {:ok, _msg1} = Chat.send_message(conv.id, user.id, "First")
      {:ok, _msg2} = Chat.send_message(conv.id, user.id, "Second")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      # Two consecutive user messages should be merged into one
      assert length(result) == 1
      assert result |> hd() |> Map.get("content") |> length() == 2
    end

    test "handles assistant message without tool_use", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Plain Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()

      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
        )

      Projector.project_events(conv.stream_id, events)

      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_stream,
           %{
             message_id: message_id,
             full_content: "Hi there!",
             stop_reason: "end_turn",
             latency_ms: 100
           }}
        )

      Projector.project_events(conv.stream_id, events)

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      assert length(result) == 2
      assert Enum.at(result, 1)["role"] == "assistant"
      assert Enum.at(result, 1)["content"] == [%{"text" => "Hi there!"}]
    end

    test "filters out empty assistant messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Empty Asst"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()

      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
        )

      Projector.project_events(conv.stream_id, events)

      {:ok, _state, events} =
        Loader.execute(
          ConversationAggregate,
          conv.stream_id,
          {:complete_stream,
           %{
             message_id: message_id,
             full_content: "",
             stop_reason: "end_turn",
             latency_ms: 100
           }}
        )

      Projector.project_events(conv.stream_id, events)

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      result = MessageBuilder.build_llm_messages(messages)

      # Empty assistant message should be filtered out
      assert length(result) == 1
      assert hd(result)["role"] == "user"
    end

    test "handles tool_use with empty content and no completed tool calls" do
      msg = %Liteskill.Chat.Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        content: "",
        status: "complete",
        stop_reason: "tool_use",
        tool_calls: [
          %Liteskill.Chat.ToolCall{
            tool_use_id: "tc-empty",
            tool_name: "test",
            input: %{},
            output: nil,
            status: "started"
          }
        ]
      }

      result = MessageBuilder.build_llm_messages([msg])

      # No completed tool calls, so just assistant message with toolUse block (no tool result user message)
      assert length(result) == 1
      assistant_msg = hd(result)
      assert assistant_msg["role"] == "assistant"
      # Content should only have toolUse (no text block since content is empty)
      assert [%{"toolUse" => _}] = assistant_msg["content"]
    end
  end

  describe "tool_calls_for_message/1" do
    test "returns tool calls when preloaded", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "TC Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      msg = hd(messages) |> Repo.preload(:tool_calls)

      result = MessageBuilder.tool_calls_for_message(msg)
      assert result == []
    end

    test "loads tool calls from DB when not preloaded", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "TC Load Test"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      msg = hd(messages)

      result = MessageBuilder.tool_calls_for_message(msg)
      assert result == []
    end
  end

  describe "format_tool_output (via build_llm_messages)" do
    test "handles nil output" do
      # Create a minimal tool call scenario
      msg = %Liteskill.Chat.Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        content: "test",
        status: "complete",
        stop_reason: "tool_use",
        tool_calls: [
          %Liteskill.Chat.ToolCall{
            tool_use_id: "tc-1",
            tool_name: "test",
            input: %{},
            output: nil,
            status: "completed"
          }
        ]
      }

      result = MessageBuilder.build_llm_messages([msg])
      tool_result = Enum.at(result, 1)

      text =
        get_in(tool_result, [
          "content",
          Access.at(0),
          "toolResult",
          "content",
          Access.at(0),
          "text"
        ])

      assert text == ""
    end

    test "handles content list with non-text items" do
      msg = %Liteskill.Chat.Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        content: "test",
        status: "complete",
        stop_reason: "tool_use",
        tool_calls: [
          %Liteskill.Chat.ToolCall{
            tool_use_id: "tc-mixed",
            tool_name: "test",
            input: %{},
            output: %{"content" => [%{"image" => "base64data"}]},
            status: "completed"
          }
        ]
      }

      result = MessageBuilder.build_llm_messages([msg])
      tool_result = Enum.at(result, 1)

      text =
        get_in(tool_result, [
          "content",
          Access.at(0),
          "toolResult",
          "content",
          Access.at(0),
          "text"
        ])

      assert text == "{\"image\":\"base64data\"}"
    end

    test "handles map output" do
      msg = %Liteskill.Chat.Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        content: "test",
        status: "complete",
        stop_reason: "tool_use",
        tool_calls: [
          %Liteskill.Chat.ToolCall{
            tool_use_id: "tc-2",
            tool_name: "test",
            input: %{},
            output: %{"key" => "val"},
            status: "completed"
          }
        ]
      }

      result = MessageBuilder.build_llm_messages([msg])
      tool_result = Enum.at(result, 1)

      text =
        get_in(tool_result, [
          "content",
          Access.at(0),
          "toolResult",
          "content",
          Access.at(0),
          "text"
        ])

      assert text == "{\"key\":\"val\"}"
    end

    test "handles non-map output" do
      msg = %Liteskill.Chat.Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        content: "",
        status: "complete",
        stop_reason: "tool_use",
        tool_calls: [
          %Liteskill.Chat.ToolCall{
            tool_use_id: "tc-3",
            tool_name: "test",
            input: %{},
            output: 42,
            status: "completed"
          }
        ]
      }

      result = MessageBuilder.build_llm_messages([msg])
      tool_result = Enum.at(result, 1)

      text =
        get_in(tool_result, [
          "content",
          Access.at(0),
          "toolResult",
          "content",
          Access.at(0),
          "text"
        ])

      assert text == "42"
    end
  end

  describe "strip_tool_blocks/1" do
    test "removes toolUse and toolResult blocks from messages" do
      messages = [
        %{"role" => "user", "content" => [%{"text" => "hello"}]},
        %{
          "role" => "assistant",
          "content" => [
            %{"text" => "Let me use a tool"},
            %{"toolUse" => %{"toolUseId" => "t1", "name" => "search", "input" => %{}}}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"toolResult" => %{"toolUseId" => "t1", "content" => [%{"text" => "result"}]}}
          ]
        },
        %{"role" => "assistant", "content" => [%{"text" => "Based on the tool result..."}]}
      ]

      stripped = MessageBuilder.strip_tool_blocks(messages)

      # After stripping: user(text), assistant(text only), assistant(text)
      # The toolResult-only user message is dropped (empty content)
      # merge_consecutive_roles merges the two consecutive assistant messages
      # Result: [user, assistant(merged)]
      assert length(stripped) == 2

      assert Enum.at(stripped, 0)["role"] == "user"
      assert Enum.at(stripped, 0)["content"] == [%{"text" => "hello"}]

      assert Enum.at(stripped, 1)["role"] == "assistant"
      merged_texts = Enum.map(Enum.at(stripped, 1)["content"], & &1["text"])
      assert "Let me use a tool" in merged_texts
      assert "Based on the tool result..." in merged_texts
    end

    test "passes through messages without tool blocks unchanged" do
      messages = [
        %{"role" => "user", "content" => [%{"text" => "hello"}]},
        %{"role" => "assistant", "content" => [%{"text" => "hi there"}]}
      ]

      assert MessageBuilder.strip_tool_blocks(messages) == messages
    end

    test "returns empty list when all content is tool blocks" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{"toolUse" => %{"toolUseId" => "t1", "name" => "search", "input" => %{}}}
          ]
        }
      ]

      assert MessageBuilder.strip_tool_blocks(messages) == []
    end
  end
end
