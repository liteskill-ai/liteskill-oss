defmodule Liteskill.Accounts.AuthEventTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Accounts

  defp create_user(_context \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        email: "event-test-#{unique}@example.com",
        name: "Event Test",
        oidc_sub: "event-#{unique}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "log_auth_event/1" do
    test "creates an auth event with all fields" do
      %{user: user} = create_user()

      {:ok, event} =
        Accounts.log_auth_event(%{
          event_type: "login_success",
          user_id: user.id,
          ip_address: "192.168.1.1",
          user_agent: "TestBrowser/1.0",
          metadata: %{"method" => "password"}
        })

      assert event.event_type == "login_success"
      assert event.user_id == user.id
      assert event.ip_address == "192.168.1.1"
      assert event.user_agent == "TestBrowser/1.0"
      assert event.metadata == %{"method" => "password"}
      assert event.inserted_at
    end

    test "creates an auth event without user_id (failed login with unknown email)" do
      {:ok, event} =
        Accounts.log_auth_event(%{
          event_type: "login_failure",
          ip_address: "10.0.0.1",
          metadata: %{"email" => "unknown@example.com"}
        })

      assert event.event_type == "login_failure"
      assert event.user_id == nil
    end

    test "creates an auth event with minimal fields" do
      {:ok, event} = Accounts.log_auth_event(%{event_type: "session_expired"})
      assert event.event_type == "session_expired"
      assert event.metadata == %{}
    end
  end

  describe "list_auth_events/2" do
    test "returns events for a user ordered by most recent first" do
      %{user: user} = create_user()

      Accounts.log_auth_event(%{event_type: "login_success", user_id: user.id})
      Accounts.log_auth_event(%{event_type: "logout", user_id: user.id})

      events = Accounts.list_auth_events(user.id)
      assert length(events) == 2
      assert hd(events).event_type == "logout"
    end

    test "respects limit option" do
      %{user: user} = create_user()

      for _ <- 1..5, do: Accounts.log_auth_event(%{event_type: "login_success", user_id: user.id})

      events = Accounts.list_auth_events(user.id, limit: 3)
      assert length(events) == 3
    end

    test "returns empty list for user with no events" do
      %{user: user} = create_user()
      assert Accounts.list_auth_events(user.id) == []
    end
  end
end
