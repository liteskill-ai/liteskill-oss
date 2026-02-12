defmodule Liteskill.Chat.StreamRecoveryTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat
  alias Liteskill.Chat.{Conversation, StreamRecovery}

  import Ecto.Query

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "recovery-#{System.unique_integer([:positive])}@example.com",
        name: "Recovery Tester",
        oidc_sub: "recovery-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  defp create_stuck_conversation(user) do
    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Stuck"})
    {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

    alias Liteskill.Aggregate.Loader
    alias Liteskill.Chat.{ConversationAggregate, Projector}

    message_id = Ecto.UUID.generate()
    command = {:start_assistant_stream, %{message_id: message_id, model_id: "test-model"}}
    {:ok, _state, events} = Loader.execute(ConversationAggregate, conv.stream_id, command)
    Projector.project_events(conv.stream_id, events)

    conv
  end

  defp backdate_conversation(conv_id, minutes_ago) do
    past = DateTime.utc_now() |> DateTime.add(-minutes_ago * 60, :second)

    from(c in Conversation, where: c.id == ^conv_id)
    |> Repo.update_all(set: [updated_at: past])
  end

  describe "periodic sweep" do
    test "recovers stuck streaming conversations on sweep", %{user: user} do
      conv = create_stuck_conversation(user)

      assert Repo.get!(Conversation, conv.id).status == "streaming"

      # Backdate so it exceeds the 1-minute threshold
      backdate_conversation(conv.id, 10)

      {:ok, pid} =
        StreamRecovery.start_link(
          sweep_interval_ms: 50,
          threshold_minutes: 1,
          name: :test_stream_recovery
        )

      Process.sleep(100)

      recovered = Repo.get!(Conversation, conv.id)
      assert recovered.status == "active"

      GenServer.stop(pid)
    end

    test "does not recover conversations within threshold", %{user: user} do
      conv = create_stuck_conversation(user)

      # Do NOT backdate — conversation was just created (within threshold)
      {:ok, pid} =
        StreamRecovery.start_link(
          sweep_interval_ms: 50,
          threshold_minutes: 60,
          name: :test_stream_recovery_threshold
        )

      Process.sleep(100)

      still_streaming = Repo.get!(Conversation, conv.id)
      assert still_streaming.status == "streaming"

      GenServer.stop(pid)

      # Clean up
      Chat.recover_stream_by_id(conv.id)
    end
  end
end
