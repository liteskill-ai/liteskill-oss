defmodule Liteskill.Chat.ProjectorTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat.{Conversation, Message, MessageChunk, ToolCall, Projector}
  alias Liteskill.EventStore.Postgres, as: Store

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "projector-test-#{System.unique_integer([:positive])}@example.com",
        name: "Test",
        oidc_sub: "proj-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  test "projects ConversationCreated event", %{user: user} do
    conversation_id = Ecto.UUID.generate()
    stream_id = "conversation-#{conversation_id}"

    {:ok, events} =
      Store.append_events(stream_id, 0, [
        %{
          event_type: "ConversationCreated",
          data: %{
            "conversation_id" => conversation_id,
            "user_id" => user.id,
            "title" => "Test Chat",
            "model_id" => "claude",
            "system_prompt" => "Be helpful"
          }
        }
      ])

    Projector.project_events(stream_id, events)

    conversation = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conversation.title == "Test Chat"
    assert conversation.status == "active"
    assert conversation.user_id == user.id
    assert conversation.system_prompt == "Be helpful"
  end

  test "projects UserMessageAdded event", %{user: user} do
    {stream_id, _} = create_conversation(user)

    message_id = Ecto.UUID.generate()

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "UserMessageAdded",
          data: %{
            "message_id" => message_id,
            "content" => "Hello!",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.role == "user"
    assert message.content == "Hello!"
    assert message.position == 1
    assert message.status == "complete"

    conversation = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conversation.message_count == 1
    assert conversation.last_message_at != nil
  end

  test "projects UserMessageAdded event with tool_config", %{user: user} do
    {stream_id, _} = create_conversation(user)

    message_id = Ecto.UUID.generate()

    tool_config = %{
      "servers" => [%{"id" => "srv-1", "name" => "Context7"}],
      "tools" => [%{"toolSpec" => %{"name" => "resolve-library-id"}}],
      "auto_confirm" => true
    }

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "UserMessageAdded",
          data: %{
            "message_id" => message_id,
            "content" => "Hello!",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "tool_config" => tool_config
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.tool_config == tool_config
  end

  test "projects assistant stream lifecycle with chunks", %{user: user} do
    {stream_id, _} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    # Start stream
    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.status == "streaming"
    assert message.model_id == "claude"

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.status == "streaming"
    assert conv.message_count == 1

    # Chunk
    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantChunkReceived",
          data: %{
            "message_id" => message_id,
            "chunk_index" => 0,
            "content_block_index" => 0,
            "delta_type" => "text_delta",
            "delta_text" => "Hello"
          }
        }
      ])

    Projector.project_events(stream_id, events)

    chunks = Repo.all(from mc in MessageChunk, where: mc.message_id == ^message_id)
    assert length(chunks) == 1
    assert Enum.at(chunks, 0).delta_text == "Hello"

    # Complete stream
    {:ok, events} =
      Store.append_events(stream_id, 3, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => "Hello there!",
            "stop_reason" => "end_turn",
            "input_tokens" => 10,
            "output_tokens" => 5,
            "latency_ms" => 150,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.status == "complete"
    assert message.content == "Hello there!"
    assert message.input_tokens == 10
    assert message.output_tokens == 5
    assert message.total_tokens == 15
    assert message.latency_ms == 150

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.status == "active"
  end

  test "projects AssistantStreamFailed event", %{user: user} do
    {stream_id, _} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamFailed",
          data: %{
            "message_id" => message_id,
            "error_type" => "rate_limit",
            "error_message" => "429",
            "retry_count" => 0,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.status == "active"
  end

  test "projects tool call lifecycle", %{user: user} do
    {stream_id, _} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    tool_use_id = "tool-#{System.unique_integer([:positive])}"

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "ToolCallStarted",
          data: %{
            "message_id" => message_id,
            "tool_use_id" => tool_use_id,
            "tool_name" => "calculator",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    tc = Repo.one!(from t in ToolCall, where: t.tool_use_id == ^tool_use_id)
    assert tc.status == "started"
    assert tc.tool_name == "calculator"

    {:ok, events} =
      Store.append_events(stream_id, 3, [
        %{
          event_type: "ToolCallCompleted",
          data: %{
            "message_id" => message_id,
            "tool_use_id" => tool_use_id,
            "tool_name" => "calculator",
            "input" => %{"expr" => "2+2"},
            "output" => %{"result" => 4},
            "duration_ms" => 50,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    tc = Repo.one!(from t in ToolCall, where: t.tool_use_id == ^tool_use_id)
    assert tc.status == "completed"
    assert tc.input == %{"expr" => "2+2"}
    assert tc.output == %{"result" => 4}
    assert tc.duration_ms == 50
  end

  test "projects ConversationTitleUpdated event", %{user: user} do
    {stream_id, _} = create_conversation(user)

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "ConversationTitleUpdated",
          data: %{
            "title" => "Updated Title",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.title == "Updated Title"
  end

  test "projects ConversationArchived event", %{user: user} do
    {stream_id, _} = create_conversation(user)

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "ConversationArchived",
          data: %{"timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()}
        }
      ])

    Projector.project_events(stream_id, events)

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.status == "archived"
  end

  test "projects ConversationForked event", %{user: user} do
    {parent_stream_id, _} = create_conversation(user)

    new_conv_id = Ecto.UUID.generate()
    new_stream_id = "conversation-#{new_conv_id}"

    {:ok, events} =
      Store.append_events(new_stream_id, 0, [
        %{
          event_type: "ConversationCreated",
          data: %{
            "conversation_id" => new_conv_id,
            "user_id" => user.id,
            "title" => "Fork",
            "model_id" => "claude",
            "system_prompt" => nil
          }
        },
        %{
          event_type: "ConversationForked",
          data: %{
            "new_conversation_id" => new_conv_id,
            "parent_stream_id" => parent_stream_id,
            "fork_at_version" => 1,
            "user_id" => user.id,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(new_stream_id, events)

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^new_stream_id)
    assert conv.parent_conversation_id != nil
    assert conv.fork_at_version == 1
  end

  test "handles unknown event type gracefully", %{user: user} do
    {stream_id, _} = create_conversation(user)

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{event_type: "UnknownEvent", data: %{"foo" => "bar"}}
      ])

    # Should not crash
    Projector.project_events(stream_id, events)
  end

  test "projects AssistantStreamFailed when message does not exist", %{user: user} do
    {stream_id, _} = create_conversation(user)

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamFailed",
          data: %{
            "message_id" => Ecto.UUID.generate(),
            "error_type" => "rate_limit",
            "error_message" => "429",
            "retry_count" => 0,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    conv = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)
    assert conv.status == "active"
  end

  test "handles events for missing conversation gracefully" do
    # Project an event for a stream that has no ConversationCreated projection.
    # The projector should log a warning and not crash.
    fake_stream_id = "conversation-#{Ecto.UUID.generate()}"

    {:ok, events} =
      Store.append_events(fake_stream_id, 0, [
        %{
          event_type: "UserMessageAdded",
          data: %{
            "message_id" => Ecto.UUID.generate(),
            "content" => "Orphan message",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    # Should not raise — the projector should skip gracefully
    Projector.project_events(fake_stream_id, events)

    # Projector should still be alive
    assert Process.alive?(Process.whereis(Liteskill.Chat.Projector))
  end

  test "handles ToolCallCompleted for missing tool call gracefully" do
    # ToolCallCompleted for a tool_use_id that doesn't exist in projections
    fake_stream_id = "conversation-#{Ecto.UUID.generate()}"

    {:ok, events} =
      Store.append_events(fake_stream_id, 0, [
        %{
          event_type: "ToolCallCompleted",
          data: %{
            "tool_use_id" => "nonexistent-tool-#{System.unique_integer([:positive])}",
            "input" => %{},
            "output" => %{"result" => "ok"},
            "duration_ms" => 10,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    # Should not raise
    Projector.project_events(fake_stream_id, events)

    assert Process.alive?(Process.whereis(Liteskill.Chat.Projector))
  end

  test "handles info messages that are not events" do
    # The projector GenServer should handle unexpected messages
    send(Liteskill.Chat.Projector, :unexpected_message)
    _ = :sys.get_state(Liteskill.Chat.Projector)
    # Should still be alive
    assert Process.alive?(Process.whereis(Liteskill.Chat.Projector))
  end

  test "rebuild_projections replays all events", %{user: user} do
    {_stream_id, _} = create_conversation(user)

    result = Projector.rebuild_projections()
    assert {:ok, _} = result
  end

  test "projects stream completed with nil tokens", %{user: user} do
    {stream_id, _} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => "Hi",
            "stop_reason" => "end_turn",
            "input_tokens" => nil,
            "output_tokens" => nil,
            "latency_ms" => nil,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.total_tokens == nil
  end

  test "filter_cited_sources: keeps only cited sources from rag_sources", %{user: user} do
    {stream_id, _conv_id} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    doc_id_cited = Ecto.UUID.generate()
    doc_id_uncited = Ecto.UUID.generate()

    rag_sources = [
      %{"document_id" => doc_id_cited, "content" => "cited"},
      %{"document_id" => doc_id_uncited, "content" => "not cited"}
    ]

    # Start stream
    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    # Set rag_sources on the message
    message = Repo.get!(Message, message_id)
    message |> Message.changeset(%{rag_sources: rag_sources}) |> Repo.update!()

    # Complete with content that cites one source
    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => "Here is info [uuid:#{doc_id_cited}].",
            "stop_reason" => "end_turn",
            "input_tokens" => 10,
            "output_tokens" => 5,
            "latency_ms" => 100,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert length(message.rag_sources) == 1
    assert hd(message.rag_sources)["document_id"] == doc_id_cited
  end

  test "filter_cited_sources: returns nil when no sources are cited", %{user: user} do
    {stream_id, _conv_id} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    rag_sources = [
      %{"document_id" => Ecto.UUID.generate(), "content" => "not cited"}
    ]

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    message |> Message.changeset(%{rag_sources: rag_sources}) |> Repo.update!()

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => "No citations here.",
            "stop_reason" => "end_turn",
            "input_tokens" => 10,
            "output_tokens" => 5,
            "latency_ms" => 100,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.rag_sources == nil
  end

  test "filter_cited_sources: preserves empty list when rag_sources is []", %{user: user} do
    {stream_id, _conv_id} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    message |> Message.changeset(%{rag_sources: []}) |> Repo.update!()

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => "Hello.",
            "stop_reason" => "end_turn",
            "input_tokens" => 10,
            "output_tokens" => 5,
            "latency_ms" => 100,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.rag_sources == []
  end

  test "filter_cited_sources: returns nil when content is nil but sources exist", %{user: user} do
    {stream_id, _conv_id} = create_conversation(user)
    message_id = Ecto.UUID.generate()

    rag_sources = [
      %{"document_id" => Ecto.UUID.generate(), "content" => "some source"}
    ]

    {:ok, events} =
      Store.append_events(stream_id, 1, [
        %{
          event_type: "AssistantStreamStarted",
          data: %{
            "message_id" => message_id,
            "model_id" => "claude",
            "request_id" => Ecto.UUID.generate(),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    message |> Message.changeset(%{rag_sources: rag_sources}) |> Repo.update!()

    {:ok, events} =
      Store.append_events(stream_id, 2, [
        %{
          event_type: "AssistantStreamCompleted",
          data: %{
            "message_id" => message_id,
            "full_content" => nil,
            "stop_reason" => "end_turn",
            "input_tokens" => 10,
            "output_tokens" => 5,
            "latency_ms" => 100,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ])

    Projector.project_events(stream_id, events)

    message = Repo.get!(Message, message_id)
    assert message.rag_sources == nil
  end

  defp create_conversation(user) do
    conversation_id = Ecto.UUID.generate()
    stream_id = "conversation-#{conversation_id}"

    {:ok, events} =
      Store.append_events(stream_id, 0, [
        %{
          event_type: "ConversationCreated",
          data: %{
            "conversation_id" => conversation_id,
            "user_id" => user.id,
            "title" => "Test",
            "model_id" => "claude",
            "system_prompt" => nil
          }
        }
      ])

    Projector.project_events(stream_id, events)

    {stream_id, conversation_id}
  end
end
