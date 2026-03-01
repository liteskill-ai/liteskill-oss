defmodule LiteskillWeb.Plugs.AuthTest do
  use LiteskillWeb.ConnCase, async: true

  alias LiteskillWeb.Plugs.Auth

  describe "init/1" do
    test "returns the action passed" do
      assert Auth.init(:fetch_current_user) == :fetch_current_user
      assert Auth.init(:require_authenticated_user) == :require_authenticated_user
    end
  end

  describe "call/2 dispatches to the correct function" do
    test "dispatches :fetch_current_user", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Auth.call(:fetch_current_user)

      assert conn.assigns[:current_user] == nil
    end

    test "dispatches :require_authenticated_user", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> assign(:current_user, nil)
        |> put_req_header("accept", "application/json")
        |> Auth.call(:require_authenticated_user)

      assert conn.halted
      assert json_response(conn, 401)["error"] == "authentication required"
    end
  end

  describe "fetch_current_user/2" do
    test "assigns nil when no session_token in session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Auth.fetch_current_user()

      assert conn.assigns.current_user == nil
    end

    test "assigns user when valid session_token is in session", %{conn: conn} do
      {:ok, user} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "plug-test-#{System.unique_integer([:positive])}@example.com",
          name: "Plug Test",
          oidc_sub: "plug-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, session} = Liteskill.Accounts.create_session(user.id)

      conn =
        conn
        |> init_test_session(%{session_token: session.id})
        |> Auth.fetch_current_user()

      assert conn.assigns.current_user.id == user.id
    end

    test "touches session when last_active_at is stale", %{conn: conn} do
      import Ecto.Query

      {:ok, user} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "plug-touch-#{System.unique_integer([:positive])}@example.com",
          name: "Plug Touch Test",
          oidc_sub: "plug-touch-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, session} = Liteskill.Accounts.create_session(user.id)

      # Set last_active_at to 120 seconds ago to trigger touch
      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        from(s in Liteskill.Accounts.UserSession, where: s.id == ^session.id),
        set: [last_active_at: past]
      )

      conn =
        conn
        |> init_test_session(%{session_token: session.id})
        |> Auth.fetch_current_user()

      assert conn.assigns.current_user.id == user.id

      # Verify session was touched
      {updated_session, _user} = Liteskill.Accounts.validate_session_with_user(session.id)
      assert DateTime.after?(updated_session.last_active_at, past)
    end

    test "assigns nil when session_token not found in database", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{session_token: Ecto.UUID.generate()})
        |> Auth.fetch_current_user()

      assert conn.assigns.current_user == nil
    end
  end

  describe "fetch_current_user/2 in single-user mode" do
    setup do
      original = Application.get_env(:liteskill, :single_user_mode)
      Application.put_env(:liteskill, :single_user_mode, true)
      admin = Liteskill.Accounts.ensure_admin_user()

      on_exit(fn ->
        Application.put_env(:liteskill, :single_user_mode, original || false)
      end)

      %{admin: admin}
    end

    test "auto-assigns admin user without session", %{conn: conn, admin: admin} do
      conn =
        conn
        |> init_test_session(%{})
        |> Auth.fetch_current_user()

      assert conn.assigns.current_user.id == admin.id
    end
  end

  describe "require_authenticated_user/2" do
    test "passes through when user is assigned", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> assign(:current_user, %{id: "user-1"})
        |> Auth.require_authenticated_user()

      refute conn.halted
    end

    test "halts and returns 401 when no user", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> assign(:current_user, nil)
        |> put_req_header("accept", "application/json")
        |> Auth.require_authenticated_user()

      assert conn.halted
      assert conn.status == 401
    end
  end
end
