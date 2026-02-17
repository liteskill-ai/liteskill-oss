defmodule Liteskill.ChatTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "chat-test-#{System.unique_integer([:positive])}@example.com",
        name: "Chat Tester",
        oidc_sub: "chat-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other_user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user, other_user: other_user}
  end

  describe "create_conversation/1" do
    test "creates a conversation with explicit title", %{user: user} do
      assert {:ok, conversation} =
               Chat.create_conversation(%{user_id: user.id, title: "My Chat"})

      assert conversation.title == "My Chat"
      assert conversation.status == "active"
      assert conversation.user_id == user.id
      assert conversation.stream_id != nil
    end

    test "creates with default title", %{user: user} do
      assert {:ok, conversation} = Chat.create_conversation(%{user_id: user.id})
      assert conversation.title == "New Conversation"
    end

    test "accepts optional model_id and system_prompt", %{user: user} do
      assert {:ok, conversation} =
               Chat.create_conversation(%{
                 user_id: user.id,
                 model_id: "custom-model",
                 system_prompt: "Be brief"
               })

      assert conversation.model_id == "custom-model"
      assert conversation.system_prompt == "Be brief"
    end

    test "resolves model_id from llm_model_id", %{user: user} do
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Test Provider",
          provider_type: "amazon_bedrock",
          api_key: "test-key",
          provider_config: %{"region" => "us-east-1"},
          user_id: user.id
        })

      {:ok, llm_model} =
        Liteskill.LlmModels.create_model(%{
          name: "Test Model",
          model_id: "us.anthropic.claude-3-5-sonnet",
          provider_id: provider.id,
          user_id: user.id
        })

      assert {:ok, conversation} =
               Chat.create_conversation(%{user_id: user.id, llm_model_id: llm_model.id})

      assert conversation.model_id == "us.anthropic.claude-3-5-sonnet"
    end

    test "falls back to model_id param when llm_model_id is not accessible", %{user: user} do
      assert {:ok, conversation} =
               Chat.create_conversation(%{
                 user_id: user.id,
                 llm_model_id: Ecto.UUID.generate(),
                 model_id: "fallback-model-id"
               })

      assert conversation.model_id == "fallback-model-id"
    end

    test "returns error when model_id resolves to nil", %{user: user} do
      assert {:error, :no_model_configured} =
               Chat.create_conversation(%{
                 user_id: user.id,
                 llm_model_id: Ecto.UUID.generate()
               })
    end

    test "auto-creates owner ACL", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      acl =
        Repo.one!(
          from a in Liteskill.Authorization.EntityAcl,
            where:
              a.entity_type == "conversation" and a.entity_id == ^conv.id and
                a.user_id == ^user.id
        )

      assert acl.role == "owner"
    end
  end

  describe "send_message/3" do
    test "adds a user message", %{user: user} do
      {:ok, conversation} = Chat.create_conversation(%{user_id: user.id})
      {:ok, message} = Chat.send_message(conversation.id, user.id, "Hello!")

      assert message.role == "user"
      assert message.content == "Hello!"
      assert message.position == 1
    end

    test "returns error for archived conversation", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.archive_conversation(conv.id, user.id)

      assert {:error, :conversation_archived} = Chat.send_message(conv.id, user.id, "Hi")
    end

    test "returns not_found for another user's conversation", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.send_message(conv.id, other.id, "Hi")
    end

    test "shared user can send messages", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _acl} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      {:ok, message} = Chat.send_message(conv.id, other.id, "Hello from shared!")
      assert message.content == "Hello from shared!"
    end

    test "persists tool_config when provided", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      tool_config = %{
        "servers" => [%{"id" => "srv-1", "name" => "Context7"}],
        "tools" => [%{"toolSpec" => %{"name" => "resolve-library-id"}}],
        "tool_name_to_server_id" => %{"resolve-library-id" => "srv-1"},
        "auto_confirm" => true
      }

      {:ok, message} =
        Chat.send_message(conv.id, user.id, "Hello!", tool_config: tool_config)

      assert message.tool_config == tool_config
    end

    test "tool_config defaults to nil when not provided", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, message} = Chat.send_message(conv.id, user.id, "Hello!")

      assert message.tool_config == nil
    end
  end

  describe "list_conversations/2" do
    test "lists user conversations", %{user: user} do
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Chat 1"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Chat 2"})

      conversations = Chat.list_conversations(user.id)
      assert length(conversations) == 2
    end

    test "excludes archived conversations", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Archived"})
      {:ok, _} = Chat.archive_conversation(conv.id, user.id)

      conversations = Chat.list_conversations(user.id)
      assert Enum.empty?(conversations)
    end

    test "supports limit and offset", %{user: user} do
      for i <- 1..5 do
        {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Chat #{i}"})
      end

      assert length(Chat.list_conversations(user.id, limit: 2)) == 2
      assert length(Chat.list_conversations(user.id, limit: 2, offset: 4)) == 1
    end

    test "does not list other user's conversations", %{user: user, other_user: other} do
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "User's Chat"})

      assert Chat.list_conversations(other.id) == []
    end

    test "includes shared conversations", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Shared"})
      {:ok, _acl} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      conversations = Chat.list_conversations(other.id)
      assert length(conversations) == 1
      assert hd(conversations).id == conv.id
    end

    test "filters by search term", %{user: user} do
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Alpha project"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Beta project"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Gamma release"})

      assert length(Chat.list_conversations(user.id, search: "project")) == 2
      assert length(Chat.list_conversations(user.id, search: "gamma")) == 1
      assert Chat.list_conversations(user.id, search: "nonexistent") == []
    end

    test "search escapes percent characters", %{user: user} do
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "100% done"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Other chat"})

      assert length(Chat.list_conversations(user.id, search: "100%")) == 1
    end
  end

  describe "count_conversations/2" do
    test "returns total count", %{user: user} do
      for i <- 1..3, do: Chat.create_conversation(%{user_id: user.id, title: "Chat #{i}"})
      assert Chat.count_conversations(user.id) == 3
    end

    test "excludes archived", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Archived"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Active"})
      Chat.archive_conversation(conv.id, user.id)

      assert Chat.count_conversations(user.id) == 1
    end

    test "respects search filter", %{user: user} do
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Alpha"})
      {:ok, _} = Chat.create_conversation(%{user_id: user.id, title: "Beta"})

      assert Chat.count_conversations(user.id, search: "Alpha") == 1
    end

    test "includes shared conversations", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Shared"})
      {:ok, _} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert Chat.count_conversations(other.id) == 1
    end
  end

  describe "bulk_archive_conversations/2" do
    test "archives multiple conversations", %{user: user} do
      {:ok, c1} = Chat.create_conversation(%{user_id: user.id, title: "Chat 1"})
      {:ok, c2} = Chat.create_conversation(%{user_id: user.id, title: "Chat 2"})
      {:ok, _c3} = Chat.create_conversation(%{user_id: user.id, title: "Chat 3"})

      assert {:ok, 2} = Chat.bulk_archive_conversations([c1.id, c2.id], user.id)
      assert length(Chat.list_conversations(user.id)) == 1
    end

    test "returns ok with 0 for empty list", %{user: _user} do
      assert {:ok, 0} = Chat.bulk_archive_conversations([], "any-user-id")
    end

    test "skips unauthorized conversations", %{user: user, other_user: other} do
      {:ok, own} = Chat.create_conversation(%{user_id: user.id, title: "Mine"})
      {:ok, foreign} = Chat.create_conversation(%{user_id: other.id, title: "Theirs"})

      assert {:ok, 1} = Chat.bulk_archive_conversations([own.id, foreign.id], user.id)
    end
  end

  describe "get_conversation/2" do
    test "returns conversation with messages preloaded", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Hello!")

      assert {:ok, conversation} = Chat.get_conversation(conv.id, user.id)
      assert length(conversation.messages) == 1
    end

    test "returns not_found for another user's conversation", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.get_conversation(conv.id, other.id)
    end

    test "returns not_found for nonexistent conversation", %{user: user} do
      assert {:error, :not_found} = Chat.get_conversation(Ecto.UUID.generate(), user.id)
    end

    test "shared user can get conversation", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _acl} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert {:ok, conversation} = Chat.get_conversation(conv.id, other.id)
      assert conversation.id == conv.id
    end
  end

  describe "list_messages/3" do
    test "returns messages ordered by position", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.send_message(conv.id, user.id, "First")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Second")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "First"
      assert Enum.at(messages, 1).content == "Second"
    end

    test "supports limit and offset", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.send_message(conv.id, user.id, "First")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Second")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Third")

      {:ok, msgs1} = Chat.list_messages(conv.id, user.id, limit: 1)
      assert length(msgs1) == 1

      {:ok, msgs2} = Chat.list_messages(conv.id, user.id, limit: 2, offset: 2)
      assert length(msgs2) == 1
    end

    test "returns not_found for another user's conversation", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.list_messages(conv.id, other.id)
    end
  end

  describe "get_conversation_tree/2" do
    test "returns root and descendants", %{user: user} do
      {:ok, parent} = Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Chat.send_message(parent.id, user.id, "Message 1")

      {:ok, fork} = Chat.fork_conversation(parent.id, user.id, 1)

      {:ok, tree} = Chat.get_conversation_tree(parent.id, user.id)
      assert length(tree) == 2
      ids = Enum.map(tree, & &1.id)
      assert parent.id in ids
      assert fork.id in ids
    end

    test "navigates to root from fork", %{user: user} do
      {:ok, parent} = Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Chat.send_message(parent.id, user.id, "Message 1")

      {:ok, fork} = Chat.fork_conversation(parent.id, user.id, 1)

      {:ok, tree} = Chat.get_conversation_tree(fork.id, user.id)
      root = Enum.at(tree, 0)
      assert root.id == parent.id
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.get_conversation_tree(conv.id, other.id)
    end
  end

  describe "replay_conversation/2" do
    test "reconstructs state from events", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Replay Test"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Hello!")

      {:ok, state} = Chat.replay_conversation(conv.id, user.id)
      assert state.status == :active
      assert length(state.messages) == 1
      assert state.title == "Replay Test"
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.replay_conversation(conv.id, other.id)
    end
  end

  describe "replay_from/3" do
    test "reconstructs state from a specific version", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Replay From"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "First")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Second")

      {:ok, state} = Chat.replay_from(conv.id, user.id, 2)
      assert state.messages != []
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.replay_from(conv.id, other.id, 1)
    end
  end

  describe "update_title/3" do
    test "updates the conversation title", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Old"})
      {:ok, updated} = Chat.update_title(conv.id, user.id, "New Title")

      assert updated.title == "New Title"
    end

    test "returns error for archived conversation", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.archive_conversation(conv.id, user.id)

      assert {:error, :conversation_archived} = Chat.update_title(conv.id, user.id, "Nope")
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.update_title(conv.id, other.id, "Nope")
    end
  end

  describe "archive_conversation/2" do
    test "archives the conversation", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, archived} = Chat.archive_conversation(conv.id, user.id)

      assert archived.status == "archived"
    end

    test "returns error when already archived", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.archive_conversation(conv.id, user.id)

      assert {:error, :already_archived} = Chat.archive_conversation(conv.id, user.id)
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} = Chat.archive_conversation(conv.id, other.id)
    end
  end

  describe "fork_conversation/3" do
    test "creates a branch from a conversation at position 1", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 1")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 2")

      {:ok, fork} = Chat.fork_conversation(conv.id, user.id, 1)

      assert fork.parent_conversation_id == conv.id
      assert fork.status == "active"

      {:ok, fork_state} = Chat.replay_conversation(fork.id, user.id)
      assert fork_state.messages != []
    end

    test "forks at a later position to preserve more messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 1")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 2")
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 3")

      {:ok, fork} = Chat.fork_conversation(conv.id, user.id, 2)

      assert fork.parent_conversation_id == conv.id

      {:ok, fork_state} = Chat.replay_conversation(fork.id, user.id)
      assert length(fork_state.messages) >= 2
    end

    test "returns not_found for another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Message 1")

      assert {:error, :not_found} = Chat.fork_conversation(conv.id, other.id, 1)
    end
  end

  describe "grant_conversation_access/4" do
    test "grants access to another user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:ok, acl} = Chat.grant_conversation_access(conv.id, user.id, other.id)
      assert acl.role == "manager"
      assert acl.user_id == other.id
    end

    test "grants with custom role", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:ok, acl} = Chat.grant_conversation_access(conv.id, user.id, other.id, "viewer")
      assert acl.role == "viewer"
    end

    test "returns error for non-owner", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :no_access} =
               Chat.grant_conversation_access(conv.id, other.id, user.id)
    end

    test "returns error for duplicate grant", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert {:error, %Ecto.Changeset{}} =
               Chat.grant_conversation_access(conv.id, user.id, other.id)
    end
  end

  describe "revoke_conversation_access/3" do
    test "revokes access from a user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert {:ok, _} = Chat.revoke_conversation_access(conv.id, user.id, other.id)

      # Verify access is revoked
      assert {:error, :not_found} = Chat.get_conversation(conv.id, other.id)
    end

    test "cannot revoke owner ACL", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert {:error, :cannot_revoke_owner} =
               Chat.revoke_conversation_access(conv.id, user.id, user.id)
    end

    test "returns not_found for nonexistent ACL", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :not_found} =
               Chat.revoke_conversation_access(conv.id, user.id, other.id)
    end

    test "returns error for non-owner", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :no_access} =
               Chat.revoke_conversation_access(conv.id, other.id, user.id)
    end
  end

  describe "leave_conversation/2" do
    test "user can leave a shared conversation", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_conversation_access(conv.id, user.id, other.id)

      assert {:ok, _} = Chat.leave_conversation(conv.id, other.id)

      # Verify access is gone
      assert {:error, :not_found} = Chat.get_conversation(conv.id, other.id)
    end

    test "owner cannot leave", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :owner_cannot_leave} = Chat.leave_conversation(conv.id, user.id)
    end

    test "returns not_found for user without ACL", %{other_user: other} do
      assert {:error, :not_found} =
               Chat.leave_conversation(Ecto.UUID.generate(), other.id)
    end
  end

  describe "grant_group_access/4" do
    test "grants group access to conversation", %{user: user} do
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:ok, acl} = Chat.grant_group_access(conv.id, user.id, group.id)
      assert acl.group_id == group.id
      assert acl.role == "manager"
    end

    test "returns error for non-owner", %{user: user, other_user: other} do
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})

      assert {:error, :no_access} = Chat.grant_group_access(conv.id, other.id, group.id)
    end

    test "returns error for nonexistent conversation", %{user: user} do
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)

      assert {:error, :no_access} =
               Chat.grant_group_access(Ecto.UUID.generate(), user.id, group.id)
    end
  end

  describe "tool call events" do
    test "start_tool_call includes input in event", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Tool Test"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Use a tool")

      stream_id = conv.stream_id
      message_id = Ecto.UUID.generate()

      # Start a stream so we're in :streaming state
      start_cmd = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}

      {:ok, _state, events} =
        Liteskill.Aggregate.Loader.execute(
          Liteskill.Chat.ConversationAggregate,
          stream_id,
          start_cmd
        )

      Liteskill.Chat.Projector.project_events(stream_id, events)

      # Now start a tool call with input
      tool_cmd =
        {:start_tool_call,
         %{
           message_id: message_id,
           tool_use_id: "tooluse_123",
           tool_name: "get_weather",
           input: %{"location" => "NYC"}
         }}

      {:ok, _state, tool_events} =
        Liteskill.Aggregate.Loader.execute(
          Liteskill.Chat.ConversationAggregate,
          stream_id,
          tool_cmd
        )

      Liteskill.Chat.Projector.project_events(stream_id, tool_events)

      # Verify the event has input
      all_events = Liteskill.EventStore.Postgres.read_stream_forward(stream_id)
      tc_event = Enum.find(all_events, &(&1.event_type == "ToolCallStarted"))
      assert tc_event.data["input"] == %{"location" => "NYC"}

      # Verify projected tool call has input
      tc =
        Liteskill.Repo.one!(
          from tc in Liteskill.Chat.ToolCall,
            where: tc.tool_use_id == "tooluse_123"
        )

      assert tc.input == %{"location" => "NYC"}
      assert tc.status == "started"
    end

    test "complete_tool_call works in streaming state", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Tool Streaming Test"})
      {:ok, _} = Chat.send_message(conv.id, user.id, "Use a tool")

      stream_id = conv.stream_id
      message_id = Ecto.UUID.generate()

      # Start stream, start tool call, then complete tool call while still streaming
      start_cmd = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}

      {:ok, _state, events} =
        Liteskill.Aggregate.Loader.execute(
          Liteskill.Chat.ConversationAggregate,
          stream_id,
          start_cmd
        )

      Liteskill.Chat.Projector.project_events(stream_id, events)

      tool_cmd =
        {:start_tool_call,
         %{
           message_id: message_id,
           tool_use_id: "tooluse_streaming_test",
           tool_name: "search",
           input: %{"query" => "test"}
         }}

      {:ok, _state, tool_events} =
        Liteskill.Aggregate.Loader.execute(
          Liteskill.Chat.ConversationAggregate,
          stream_id,
          tool_cmd
        )

      Liteskill.Chat.Projector.project_events(stream_id, tool_events)

      # Complete the tool call while still in :streaming state
      complete_tool_cmd =
        {:complete_tool_call,
         %{
           message_id: message_id,
           tool_use_id: "tooluse_streaming_test",
           tool_name: "search",
           input: %{"query" => "test"},
           output: %{"content" => [%{"text" => "Found 5 results"}]},
           duration_ms: 150
         }}

      assert {:ok, _state, _events} =
               Liteskill.Aggregate.Loader.execute(
                 Liteskill.Chat.ConversationAggregate,
                 stream_id,
                 complete_tool_cmd
               )
    end
  end

  describe "group-based conversation access" do
    test "group member can access conversation via group ACL", %{user: user, other_user: other} do
      # Create group and add other as member
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)
      {:ok, _} = Liteskill.Groups.add_member(group.id, user.id, other.id)

      # Create conversation and grant group access
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Team Chat"})
      {:ok, _} = Chat.grant_group_access(conv.id, user.id, group.id)

      # Other user should be able to access via group
      assert {:ok, conversation} = Chat.get_conversation(conv.id, other.id)
      assert conversation.id == conv.id
    end

    test "group member sees conversation in list", %{user: user, other_user: other} do
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)
      {:ok, _} = Liteskill.Groups.add_member(group.id, user.id, other.id)

      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Team Chat"})
      {:ok, _} = Chat.grant_group_access(conv.id, user.id, group.id)

      conversations = Chat.list_conversations(other.id)
      assert length(conversations) == 1
      assert hd(conversations).id == conv.id
    end

    test "non-group-member cannot access conversation via group ACL",
         %{user: user, other_user: other} do
      {:ok, group} = Liteskill.Groups.create_group("Private Team", user.id)
      # Don't add other as member

      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_group_access(conv.id, user.id, group.id)

      assert {:error, :not_found} = Chat.get_conversation(conv.id, other.id)
    end

    test "group member can send messages via group ACL", %{user: user, other_user: other} do
      {:ok, group} = Liteskill.Groups.create_group("Team", user.id)
      {:ok, _} = Liteskill.Groups.add_member(group.id, user.id, other.id)

      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Chat.grant_group_access(conv.id, user.id, group.id)

      {:ok, message} = Chat.send_message(conv.id, other.id, "Hello from group member!")
      assert message.content == "Hello from group member!"
    end
  end

  describe "update_message_rag_sources/3" do
    test "persists rag_sources on a message", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      message = hd(messages)

      rag_sources = [
        %{
          "chunk_id" => Ecto.UUID.generate(),
          "document_id" => Ecto.UUID.generate(),
          "document_title" => "Wiki Page",
          "source_name" => "wiki",
          "content" => "some content",
          "position" => 0,
          "relevance_score" => 0.95,
          "source_uri" => "/wiki/abc-123"
        }
      ]

      assert {:ok, updated} = Chat.update_message_rag_sources(message.id, user.id, rag_sources)
      assert updated.rag_sources == rag_sources
    end

    test "returns error for non-existent message", %{user: user} do
      assert {:error, :not_found} =
               Chat.update_message_rag_sources(Ecto.UUID.generate(), user.id, [])
    end

    test "returns not_found for unauthorized user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      message = hd(messages)

      assert {:error, :not_found} =
               Chat.update_message_rag_sources(message.id, other.id, [])
    end
  end

  describe "recover_stream/2" do
    test "recovers a conversation stuck in streaming state", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Stuck Stream"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      # Simulate a stuck streaming message via the aggregate
      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()

      command =
        {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}

      {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
      Projector.project_events(conv.stream_id, events)

      # Now recover
      assert {:ok, recovered_conv} = Chat.recover_stream(conv.id, user.id)
      assert recovered_conv.status == "active"
    end

    test "returns ok when no streaming message exists", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Normal Conv"})
      assert {:ok, _conv} = Chat.recover_stream(conv.id, user.id)
    end

    test "returns error for unauthorized user", %{user: user, other_user: other} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Private"})
      assert {:error, :not_found} = Chat.recover_stream(conv.id, other.id)
    end
  end

  describe "list_stuck_streaming/1" do
    test "returns conversations stuck in streaming for longer than threshold", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Stuck"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{Conversation, ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()
      command = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
      {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
      Projector.project_events(conv.stream_id, events)

      # Backdate updated_at to 10 minutes ago so it exceeds the threshold
      ten_min_ago = DateTime.utc_now() |> DateTime.add(-600, :second)

      from(c in Conversation, where: c.id == ^conv.id)
      |> Repo.update_all(set: [updated_at: ten_min_ago])

      # With threshold=5, it should appear (stuck for 10 min > 5 min)
      stuck = Chat.list_stuck_streaming(5)
      assert Enum.any?(stuck, &(&1.id == conv.id))

      # With threshold=15, it should NOT appear (stuck for 10 min < 15 min)
      stuck = Chat.list_stuck_streaming(15)
      refute Enum.any?(stuck, &(&1.id == conv.id))
    end

    test "does not return active conversations", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Active"})

      stuck = Chat.list_stuck_streaming(0)
      refute Enum.any?(stuck, &(&1.id == conv.id))
    end
  end

  describe "recover_stream_by_id/1" do
    test "recovers a stuck streaming conversation without user context", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Orphaned"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      alias Liteskill.Aggregate.Loader
      alias Liteskill.Chat.{ConversationAggregate, Projector}

      message_id = Ecto.UUID.generate()
      command = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
      {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
      Projector.project_events(conv.stream_id, events)

      assert :ok = Chat.recover_stream_by_id(conv.id)

      recovered = Liteskill.Repo.get!(Liteskill.Chat.Conversation, conv.id)
      assert recovered.status == "active"
    end

    test "returns ok when no streaming message exists", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Normal"})
      assert :ok = Chat.recover_stream_by_id(conv.id)
    end
  end

  describe "broadcast_tool_decision/3" do
    test "broadcasts approved decision via PubSub" do
      stream_id = "conversation-#{Ecto.UUID.generate()}"
      topic = "tool_approval:#{stream_id}"
      Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

      :ok = Chat.broadcast_tool_decision(stream_id, "tool-123", :approved)

      assert_receive {:tool_decision, "tool-123", :approved}
    end

    test "broadcasts rejected decision via PubSub" do
      stream_id = "conversation-#{Ecto.UUID.generate()}"
      topic = "tool_approval:#{stream_id}"
      Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

      :ok = Chat.broadcast_tool_decision(stream_id, "tool-456", :rejected)

      assert_receive {:tool_decision, "tool-456", :rejected}
    end
  end

  describe "truncate_conversation/3" do
    test "removes target message and everything after", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, msg1} = Chat.send_message(conv.id, user.id, "First")
      {:ok, msg2} = Chat.send_message(conv.id, user.id, "Second")
      {:ok, _msg3} = Chat.send_message(conv.id, user.id, "Third")

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      assert length(messages) == 3

      # Truncate at msg2 — removes msg2 and msg3, keeps msg1
      {:ok, updated_conv} = Chat.truncate_conversation(conv.id, user.id, msg2.id)
      assert updated_conv.message_count == 1

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      assert length(messages) == 1
      assert hd(messages).id == msg1.id
    end

    test "returns error for non-existent message", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello")

      assert {:error, :message_not_found} =
               Chat.truncate_conversation(conv.id, user.id, Ecto.UUID.generate())
    end

    test "returns error for unauthorized user", %{user: user, other_user: other_user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, msg} = Chat.send_message(conv.id, user.id, "Hello")

      assert {:error, :not_found} =
               Chat.truncate_conversation(conv.id, other_user.id, msg.id)
    end
  end

  describe "edit_message/5" do
    test "replaces target message with edited content", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, msg1} = Chat.send_message(conv.id, user.id, "Original")
      {:ok, _msg2} = Chat.send_message(conv.id, user.id, "Second")

      {:ok, new_msg} = Chat.edit_message(conv.id, user.id, msg1.id, "Edited content")

      assert new_msg.content == "Edited content"
      assert new_msg.role == "user"

      {:ok, messages} = Chat.list_messages(conv.id, user.id)
      # Original msg1 is removed, replaced by the new edited message
      assert length(messages) == 1
      assert hd(messages).id == new_msg.id
      assert hd(messages).content == "Edited content"
    end

    test "passes tool_config to new message", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, msg1} = Chat.send_message(conv.id, user.id, "Hello")

      tool_config = %{"servers" => [%{"id" => "s1", "name" => "TestServer"}]}

      {:ok, new_msg} =
        Chat.edit_message(conv.id, user.id, msg1.id, "Edited", tool_config: tool_config)

      assert new_msg.tool_config == tool_config
    end
  end
end
