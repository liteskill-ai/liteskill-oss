defmodule LiteskillWeb.Plugs.LiveAuthTest do
  use LiteskillWeb.ConnCase, async: false

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias LiteskillWeb.Plugs.LiveAuth

  require Ecto.Query

  setup do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        email: "live-auth-#{System.unique_integer([:positive])}@example.com",
        name: "LiveAuth User",
        oidc_sub: "live-auth-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, session} = Accounts.create_session(user.id)

    %{user: user, session: session}
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      endpoint: LiteskillWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{}
    }
  end

  defp assert_redirected_to(socket, path) do
    assert {:redirect, redirect_opts} = socket.redirected
    assert redirect_opts.to == path
  end

  defp with_single_user_mode(fun) do
    Application.put_env(:liteskill, :single_user_mode, true)

    try do
      fun.()
    after
      Application.put_env(:liteskill, :single_user_mode, false)
    end
  end

  defp ensure_setup_needed do
    # Ensure SingleUser.setup_needed?() returns true:
    # - single_user_mode is true (set by with_single_user_mode)
    # - setup_dismissed is false
    # - no providers in DB (sandbox is clean)
    Liteskill.Settings.update(%{setup_dismissed: false})
  end

  defp ensure_setup_complete do
    # Ensure SingleUser.setup_needed?() returns false by dismissing setup
    Liteskill.Settings.dismiss_setup()
  end

  defp ensure_admin_ready do
    Accounts.ensure_admin_user()
    admin = Accounts.get_user_by_email(User.admin_email())

    if User.setup_required?(admin) do
      password = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      Accounts.setup_admin_password(admin, password)
    end

    admin
  end

  # --- :require_authenticated (normal mode) ---

  describe "on_mount :require_authenticated" do
    test "redirects to /login when no session token" do
      socket = build_socket()
      assert {:halt, redirected} = LiveAuth.on_mount(:require_authenticated, %{}, %{}, socket)
      assert_redirected_to(redirected, "/login")
    end

    test "redirects to /login when session token is invalid" do
      socket = build_socket()
      session = %{"session_token" => Ecto.UUID.generate()}

      assert {:halt, redirected} =
               LiveAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert_redirected_to(redirected, "/login")
    end

    test "assigns current_user for valid session", %{user: user, session: sess} do
      socket = build_socket()
      session = %{"session_token" => sess.id}

      assert {:cont, updated} =
               LiveAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert updated.assigns.current_user.id == user.id
    end

    test "redirects to /setup when admin needs setup" do
      Accounts.ensure_admin_user()
      admin = Accounts.get_user_by_email(User.admin_email())
      {:ok, admin_session} = Accounts.create_session(admin.id)

      socket = build_socket()
      session = %{"session_token" => admin_session.id}

      if User.setup_required?(admin) do
        assert {:halt, redirected} =
                 LiveAuth.on_mount(:require_authenticated, %{}, session, socket)

        assert_redirected_to(redirected, "/setup")
      else
        assert {:cont, _} = LiveAuth.on_mount(:require_authenticated, %{}, session, socket)
      end
    end

    test "touches session when last_active_at is stale", %{user: user} do
      {:ok, session} = Accounts.create_session(user.id)

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.truncate(:second)

      Liteskill.Repo.update_all(
        Ecto.Query.from(s in Liteskill.Accounts.UserSession, where: s.id == ^session.id),
        set: [last_active_at: stale_time]
      )

      socket = build_socket()
      session_data = %{"session_token" => session.id}

      assert {:cont, updated} =
               LiveAuth.on_mount(:require_authenticated, %{}, session_data, socket)

      assert updated.assigns.current_user.id == user.id
    end
  end

  # --- :require_authenticated (SingleUser mode) ---

  describe "on_mount :require_authenticated (SingleUser)" do
    test "redirects to /setup when setup needed" do
      Accounts.ensure_admin_user()
      ensure_setup_needed()

      with_single_user_mode(fn ->
        # Verify precondition
        assert Liteskill.SingleUser.setup_needed?()

        socket = build_socket()
        assert {:halt, redirected} = LiveAuth.on_mount(:require_authenticated, %{}, %{}, socket)
        assert_redirected_to(redirected, "/setup")
      end)
    end

    test "assigns auto_user when setup not needed" do
      ensure_admin_ready()
      ensure_setup_complete()

      with_single_user_mode(fn ->
        # Verify precondition
        refute Liteskill.SingleUser.setup_needed?()

        socket = build_socket()
        assert {:cont, updated} = LiveAuth.on_mount(:require_authenticated, %{}, %{}, socket)
        assert updated.assigns.current_user
      end)
    end
  end

  # --- :require_admin (normal mode) ---

  describe "on_mount :require_admin" do
    test "redirects to /login when no session token" do
      socket = build_socket()
      assert {:halt, redirected} = LiveAuth.on_mount(:require_admin, %{}, %{}, socket)
      assert_redirected_to(redirected, "/login")
    end

    test "redirects to /login for invalid session" do
      socket = build_socket()
      session = %{"session_token" => Ecto.UUID.generate()}
      assert {:halt, redirected} = LiveAuth.on_mount(:require_admin, %{}, session, socket)
      assert_redirected_to(redirected, "/login")
    end

    test "redirects non-admin to /", %{user: user, session: sess} do
      socket = build_socket()
      session = %{"session_token" => sess.id}

      has_admin = Liteskill.Rbac.has_any_admin_permission?(user.id)

      result = LiveAuth.on_mount(:require_admin, %{}, session, socket)

      if has_admin do
        assert {:cont, updated} = result
        assert updated.assigns.current_user.id == user.id
      else
        assert {:halt, redirected} = result
        assert_redirected_to(redirected, "/")
      end
    end
  end

  # --- :require_admin (SingleUser mode) ---

  describe "on_mount :require_admin (SingleUser)" do
    test "redirects to /setup when setup needed" do
      Accounts.ensure_admin_user()
      ensure_setup_needed()

      with_single_user_mode(fn ->
        assert Liteskill.SingleUser.setup_needed?()
        socket = build_socket()
        assert {:halt, redirected} = LiveAuth.on_mount(:require_admin, %{}, %{}, socket)
        assert_redirected_to(redirected, "/setup")
      end)
    end

    test "assigns auto_user when setup not needed" do
      ensure_admin_ready()
      ensure_setup_complete()

      with_single_user_mode(fn ->
        refute Liteskill.SingleUser.setup_needed?()
        socket = build_socket()
        assert {:cont, updated} = LiveAuth.on_mount(:require_admin, %{}, %{}, socket)
        assert updated.assigns.current_user
      end)
    end
  end

  # --- :require_setup_needed ---

  describe "on_mount :require_setup_needed" do
    test "redirects to / when setup is not needed (normal mode)" do
      Accounts.ensure_admin_user()
      admin = Accounts.get_user_by_email(User.admin_email())

      socket = build_socket()

      if admin && User.setup_required?(admin) do
        assert {:cont, updated} = LiveAuth.on_mount(:require_setup_needed, %{}, %{}, socket)
        assert updated.assigns.current_user.id == admin.id
      else
        assert {:halt, redirected} = LiveAuth.on_mount(:require_setup_needed, %{}, %{}, socket)
        assert_redirected_to(redirected, "/")
      end
    end

    test "SingleUser mode: assigns user when setup is needed" do
      Accounts.ensure_admin_user()
      ensure_setup_needed()

      with_single_user_mode(fn ->
        assert Liteskill.SingleUser.setup_needed?()
        socket = build_socket()
        assert {:cont, updated} = LiveAuth.on_mount(:require_setup_needed, %{}, %{}, socket)
        assert updated.assigns.current_user
      end)
    end

    test "SingleUser mode: redirects to / when setup not needed" do
      ensure_admin_ready()
      ensure_setup_complete()

      with_single_user_mode(fn ->
        refute Liteskill.SingleUser.setup_needed?()
        socket = build_socket()
        assert {:halt, redirected} = LiveAuth.on_mount(:require_setup_needed, %{}, %{}, socket)
        assert_redirected_to(redirected, "/")
      end)
    end
  end

  # --- :redirect_if_authenticated ---

  describe "on_mount :redirect_if_authenticated" do
    test "continues with nil user when no session token" do
      ensure_admin_ready()

      socket = build_socket()

      assert {:cont, updated} =
               LiveAuth.on_mount(:redirect_if_authenticated, %{}, %{}, socket)

      assert updated.assigns.current_user == nil
    end

    test "continues with nil user for invalid session token" do
      ensure_admin_ready()

      socket = build_socket()
      session = %{"session_token" => Ecto.UUID.generate()}

      assert {:cont, updated} =
               LiveAuth.on_mount(:redirect_if_authenticated, %{}, session, socket)

      assert updated.assigns.current_user == nil
    end

    test "redirects to / for authenticated user", %{session: sess} do
      ensure_admin_ready()

      socket = build_socket()
      session = %{"session_token" => sess.id}

      assert {:halt, redirected} =
               LiveAuth.on_mount(:redirect_if_authenticated, %{}, session, socket)

      assert_redirected_to(redirected, "/")
    end

    test "redirects to /setup when admin needs setup" do
      Accounts.ensure_admin_user()
      admin = Accounts.get_user_by_email(User.admin_email())

      if User.setup_required?(admin) do
        socket = build_socket()

        assert {:halt, redirected} =
                 LiveAuth.on_mount(:redirect_if_authenticated, %{}, %{}, socket)

        assert_redirected_to(redirected, "/setup")
      end
    end

    test "SingleUser mode redirects to /setup when setup needed" do
      Accounts.ensure_admin_user()
      ensure_setup_needed()

      with_single_user_mode(fn ->
        assert Liteskill.SingleUser.setup_needed?()
        socket = build_socket()

        assert {:halt, redirected} =
                 LiveAuth.on_mount(:redirect_if_authenticated, %{}, %{}, socket)

        assert_redirected_to(redirected, "/setup")
      end)
    end

    test "SingleUser mode redirects to / when setup complete" do
      ensure_admin_ready()
      ensure_setup_complete()

      with_single_user_mode(fn ->
        refute Liteskill.SingleUser.setup_needed?()
        socket = build_socket()

        assert {:halt, redirected} =
                 LiveAuth.on_mount(:redirect_if_authenticated, %{}, %{}, socket)

        assert_redirected_to(redirected, "/")
      end)
    end
  end
end
