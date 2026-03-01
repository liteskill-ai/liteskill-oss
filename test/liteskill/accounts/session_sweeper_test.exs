defmodule Liteskill.Accounts.SessionSweeperTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Accounts
  alias Liteskill.Accounts.SessionSweeper

  defp create_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        email: "sweeper-test-#{unique}@example.com",
        name: "Sweeper Test",
        oidc_sub: "sweeper-#{unique}",
        oidc_issuer: "https://test.example.com"
      })

    user
  end

  describe "handle_info(:sweep, state)" do
    test "deletes expired sessions" do
      user = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      # Manually expire the session
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(s in Accounts.UserSession, where: s.id == ^session.id),
        set: [expires_at: past]
      )

      # Start a test-only sweeper with a long interval (won't auto-fire during test)
      pid =
        start_supervised!({SessionSweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 600_000})

      # Trigger sweep manually
      send(pid, :sweep)
      _ = :sys.get_state(pid)

      assert Accounts.validate_session_with_user(session.id) == nil
    end

    test "does not delete valid sessions" do
      user = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      pid =
        start_supervised!({SessionSweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 600_000})

      send(pid, :sweep)
      _ = :sys.get_state(pid)

      assert Accounts.validate_session_with_user(session.id)
    end
  end

  describe "handle_info catch-all" do
    test "ignores unknown messages" do
      pid =
        start_supervised!({SessionSweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 600_000})

      send(pid, :random_message)
      _ = :sys.get_state(pid)

      assert Process.alive?(pid)
    end
  end

  describe "periodic scheduling" do
    test "schedules next sweep after handling :sweep" do
      pid =
        start_supervised!({SessionSweeper, name: :"sweeper_test_#{System.unique_integer()}", interval_ms: 50})

      # The sweeper should fire within ~100ms. Sync twice to confirm it loops.
      Process.sleep(100)
      _ = :sys.get_state(pid)

      # If we got here without crash, scheduling works. Verify state is intact.
      state = :sys.get_state(pid)
      assert state.interval == 50
    end
  end
end
