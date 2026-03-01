defmodule LiteskillWeb.OpenRouterControllerTest do
  use LiteskillWeb.ConnCase, async: false

  alias Liteskill.LlmProviders
  alias Liteskill.OpenRouter

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "or-ctrl-#{System.unique_integer([:positive])}@example.com",
        name: "OpenRouter Tester",
        oidc_sub: "or-ctrl-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    conn = init_authenticated_session(build_conn(), user)

    %{conn: conn, user: user}
  end

  describe "GET /auth/openrouter (web mode)" do
    test "redirects to openrouter.ai with PKCE params", %{conn: conn} do
      conn = get(conn, ~p"/auth/openrouter?return_to=/setup")

      assert redirected_to(conn) =~ "https://openrouter.ai/auth?"
      location = redirected_to(conn)
      uri = URI.parse(location)
      params = URI.decode_query(uri.query)

      assert params["code_challenge_method"] == "S256"
      assert params["callback_url"] =~ "/auth/openrouter/callback"
      assert params["code_challenge"]

      assert get_session(conn, :openrouter_code_verifier)
      assert get_session(conn, :openrouter_return_to) == "/setup"
    end

    test "redirects to /login when unauthenticated" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/auth/openrouter")

      assert redirected_to(conn) == "/login"
    end

    test "defaults return_to to / when not provided", %{conn: conn} do
      conn = get(conn, ~p"/auth/openrouter")

      assert get_session(conn, :openrouter_return_to) == "/"
    end

    test "sanitizes return_to to prevent open redirect", %{conn: conn} do
      conn = get(conn, "/auth/openrouter?return_to=https://evil.com")

      assert get_session(conn, :openrouter_return_to) == "/"
    end

    test "rejects protocol-relative URLs in return_to", %{conn: conn} do
      conn = get(conn, "/auth/openrouter?return_to=//evil.com")

      assert get_session(conn, :openrouter_return_to) == "/"
    end

    test "allows valid relative paths in return_to", %{conn: conn} do
      conn = get(conn, "/auth/openrouter?return_to=/settings/providers")

      assert get_session(conn, :openrouter_return_to) == "/settings/providers"
    end
  end

  describe "GET /auth/openrouter/callback (session-based)" do
    test "creates provider on successful exchange", %{conn: conn, user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-new-key"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()

      conn =
        conn
        |> init_authenticated_session(user, %{
          openrouter_code_verifier: verifier,
          openrouter_return_to: "/setup"
        })
        |> get(~p"/auth/openrouter/callback?code=test_code")

      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "connected"

      provider = LlmProviders.get_provider_by_name("OpenRouter", user.id)
      assert provider
      assert provider.provider_type == "openrouter"
      assert provider.instance_wide == true
    end

    test "updates existing provider on re-auth", %{conn: conn, user: user} do
      {:ok, _} =
        LlmProviders.create_provider(%{
          name: "OpenRouter",
          provider_type: "openrouter",
          api_key: "old-key",
          instance_wide: true,
          user_id: user.id
        })

      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-updated-key"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()

      conn =
        conn
        |> init_authenticated_session(user, %{
          openrouter_code_verifier: verifier,
          openrouter_return_to: "/admin/setup"
        })
        |> get(~p"/auth/openrouter/callback?code=test_code")

      assert redirected_to(conn) == "/admin/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "updated"
    end

    test "shows error on exchange failure", %{conn: conn, user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "forbidden"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()

      conn =
        conn
        |> init_authenticated_session(user, %{
          openrouter_code_verifier: verifier,
          openrouter_return_to: "/setup"
        })
        |> get(~p"/auth/openrouter/callback?code=bad_code")

      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OpenRouter"
    end

    test "handles callback without code param", %{conn: conn, user: user} do
      conn =
        conn
        |> init_authenticated_session(user, %{
          openrouter_code_verifier: "some-verifier",
          openrouter_return_to: "/setup"
        })
        |> get(~p"/auth/openrouter/callback")

      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cancelled"
    end

    test "handles callback without session verifier", %{conn: conn, user: user} do
      conn =
        conn
        |> init_authenticated_session(user)
        |> get(~p"/auth/openrouter/callback?code=test_code")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
    end
  end

  describe "GET /auth/openrouter/callback (state-based / desktop — no session)" do
    test "creates provider and shows static HTML when no session", %{user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-desktop-key"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, user.id, "/setup")

      # No session — system browser request (desktop mode)
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/auth/openrouter/callback?code=test_code&state=#{state}")

      assert conn.status == 200
      assert conn.resp_body =~ "connected"
      assert conn.resp_body =~ "close this"

      provider = LlmProviders.get_provider_by_name("OpenRouter", user.id)
      assert provider
      assert provider.provider_type == "openrouter"
    end

    test "broadcasts PubSub on success", %{user: user} do
      topic = LiteskillWeb.OpenRouterController.openrouter_topic(user.id)
      Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-pubsub-key"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, user.id, "/setup")

      _conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/auth/openrouter/callback?code=test_code&state=#{state}")

      assert_receive :openrouter_connected
    end

    test "shows error when exchange fails via state (no session)", %{user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "forbidden"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, user.id, "/setup")

      conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/auth/openrouter/callback?code=bad_code&state=#{state}")

      assert conn.status == 200
      assert conn.resp_body =~ "failed"
    end

    test "shows error when user_id from state is invalid" do
      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, Ecto.UUID.generate(), "/setup")

      conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/auth/openrouter/callback?code=test_code&state=#{state}")

      assert conn.status == 400
      assert conn.resp_body =~ "authorization failed"
    end

    test "renders static HTML even when session user is present", %{conn: conn, user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-session-state-key"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, user.id, "/setup")

      # Request WITH a session — state-based flow should still render static HTML
      conn =
        conn
        |> init_authenticated_session(user)
        |> get(~p"/auth/openrouter/callback?code=test_code&state=#{state}")

      assert conn.status == 200
      assert conn.resp_body =~ "connected"
      assert conn.resp_body =~ "close this"

      provider = LlmProviders.get_provider_by_name("OpenRouter", user.id)
      assert provider
    end

    test "shows static error HTML even when session user is present", %{conn: conn, user: user} do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "forbidden"}))
      end)

      {verifier, _challenge} = OpenRouter.generate_pkce()
      state = OpenRouter.StateStore.store(verifier, user.id, "/setup")

      conn =
        conn
        |> init_authenticated_session(user)
        |> get(~p"/auth/openrouter/callback?code=bad_code&state=#{state}")

      assert conn.status == 200
      assert conn.resp_body =~ "failed"
    end

    test "falls through to session flow when state is invalid", %{conn: conn, user: user} do
      # Invalid state token — should fall through to session-based flow
      conn =
        conn
        |> init_authenticated_session(user)
        |> get(~p"/auth/openrouter/callback?code=test_code&state=bogus")

      # No session verifier → error flash
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
    end
  end
end
