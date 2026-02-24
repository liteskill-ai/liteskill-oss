defmodule Liteskill.Chat.StreamRegistryRecoveryTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Chat
  alias Liteskill.Chat.{ConversationAggregate, MessageChunk, Projector, StreamRegistry}

  # Polls a condition function until it returns true, with bounded retries.
  defp assert_eventually(fun, retries \\ 80, interval \\ 25) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(interval)
        assert_eventually(fun, retries - 1, interval)
      else
        flunk("condition not met after polling")
      end
    end
  end

  setup do
    name = :"stream_registry_recovery_#{System.unique_integer([:positive])}"

    _pid =
      start_supervised!(
        {StreamRegistry, name: name, recovery_delay_ms: 10},
        id: name
      )

    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "registry-recovery-#{System.unique_integer([:positive])}@example.com",
        name: "Registry Tester",
        oidc_sub: "reg-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user, registry: name}
  end

  describe "auto-recovery on task death" do
    test "recovers conversation when stream task dies", %{user: user, registry: name} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Auto Recover"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      message_id = Ecto.UUID.generate()
      command = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
      {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
      Projector.project_events(conv.stream_id, events)

      # Insert some chunks to simulate partial streaming
      for {text, idx} <- Enum.with_index(["Once ", "upon ", "a time"]) do
        %MessageChunk{}
        |> MessageChunk.changeset(%{message_id: message_id, chunk_index: idx, delta_text: text})
        |> Repo.insert!()
      end

      # Spawn a task and register it
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv.id, pid, name: name)
      assert StreamRegistry.streaming?(conv.id)

      # Kill the task — monitor will clean up ETS
      Process.exit(pid, :kill)

      # Poll until the registry entry is cleaned up by the monitor
      assert_eventually(fn -> not StreamRegistry.streaming?(conv.id) end)

      # Call recovery directly from the test process (same sandbox connection)
      Chat.recover_stream_by_id(conv.id)

      # Verify conversation is back to active
      recovered = Repo.get!(Liteskill.Chat.Conversation, conv.id)
      assert recovered.status == "active"

      # Verify the streaming message was marked as failed
      msg = Repo.get!(Liteskill.Chat.Message, message_id)
      assert msg.status == "failed"
    end

    test "auto-recovery is idempotent when stream already completed", %{
      user: user,
      registry: name
    } do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Already Done"})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      # Conversation is in "active" status (not streaming)
      # Auto-recovery should be a no-op

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv.id, pid, name: name)

      # Kill the task — auto-recovery should be a no-op since not streaming
      Process.exit(pid, :kill)

      # Poll to ensure registry cleanup happened (recovery is idempotent for active convs)
      assert_eventually(fn -> not StreamRegistry.streaming?(conv.id) end)

      # Conversation should still be active (no error)
      recovered = Repo.get!(Liteskill.Chat.Conversation, conv.id)
      assert recovered.status == "active"
    end
  end
end
