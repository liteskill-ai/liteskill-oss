defmodule Liteskill.Accounts.UserSessionTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Accounts
  alias Liteskill.Accounts.UserSession

  defp create_user(_context \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        email: "session-test-#{unique}@example.com",
        name: "Session Test",
        oidc_sub: "session-#{unique}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "create_session/2" do
    test "creates a session with valid user_id" do
      %{user: user} = create_user()

      {:ok, session} =
        Accounts.create_session(user.id, %{ip_address: "127.0.0.1", user_agent: "TestAgent"})

      assert session.user_id == user.id
      assert session.ip_address == "127.0.0.1"
      assert session.user_agent == "TestAgent"
      assert session.last_active_at
      assert session.expires_at
      assert DateTime.after?(session.expires_at, session.last_active_at)
    end

    test "creates a session without conn_info" do
      %{user: user} = create_user()

      {:ok, session} = Accounts.create_session(user.id)
      assert session.user_id == user.id
      assert session.ip_address == nil
      assert session.user_agent == nil
    end
  end

  describe "validate_session_with_user/1" do
    test "returns {session, user} tuple when valid" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      {result_session, result_user} = Accounts.validate_session_with_user(session.id)
      assert result_session.id == session.id
      assert result_user.id == user.id
    end

    test "returns nil for invalid token" do
      assert Accounts.validate_session_with_user(Ecto.UUID.generate()) == nil
    end

    test "returns nil for nil token" do
      assert Accounts.validate_session_with_user(nil) == nil
    end

    test "returns nil for expired session" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        from(s in UserSession, where: s.id == ^session.id),
        set: [expires_at: past]
      )

      assert Accounts.validate_session_with_user(session.id) == nil
    end

    test "returns nil for idle-timed-out session" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      past = DateTime.utc_now() |> DateTime.add(-200_000, :second) |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        from(s in UserSession, where: s.id == ^session.id),
        set: [last_active_at: past]
      )

      assert Accounts.validate_session_with_user(session.id) == nil
    end
  end

  describe "touch_session/1" do
    test "updates last_active_at" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      # Set last_active_at to past
      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        from(s in UserSession, where: s.id == ^session.id),
        set: [last_active_at: past]
      )

      Accounts.touch_session(session)

      {updated, _user} = Accounts.validate_session_with_user(session.id)
      assert DateTime.after?(updated.last_active_at, past)
    end
  end

  describe "delete_session/1" do
    test "deletes a session by ID" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      assert {1, _} = Accounts.delete_session(session.id)
      assert Accounts.validate_session_with_user(session.id) == nil
    end
  end

  describe "delete_and_return_session/1" do
    test "atomically deletes and returns the session" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      assert {:ok, returned} = Accounts.delete_and_return_session(session.id)
      assert returned.id == session.id
      assert returned.user_id == user.id
      assert Accounts.validate_session_with_user(session.id) == nil
    end

    test "returns :error for non-existent session" do
      assert :error = Accounts.delete_and_return_session(Ecto.UUID.generate())
    end
  end

  describe "delete_user_sessions/1" do
    test "deletes all sessions for a user" do
      %{user: user} = create_user()
      {:ok, _s1} = Accounts.create_session(user.id)
      {:ok, _s2} = Accounts.create_session(user.id)

      assert {2, _} = Accounts.delete_user_sessions(user.id)
    end
  end

  describe "delete_expired_sessions/0" do
    test "deletes sessions past their expires_at" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        from(s in UserSession, where: s.id == ^session.id),
        set: [expires_at: past]
      )

      {count, _} = Accounts.delete_expired_sessions()
      assert count >= 1
      assert Accounts.validate_session_with_user(session.id) == nil
    end

    test "does not delete valid sessions" do
      %{user: user} = create_user()
      {:ok, session} = Accounts.create_session(user.id)

      Accounts.delete_expired_sessions()
      assert Accounts.validate_session_with_user(session.id)
    end
  end
end
