defmodule LiteskillWeb.ConversationControllerTest do
  use LiteskillWeb.ConnCase, async: false

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "api-test-#{System.unique_integer([:positive])}@example.com",
        name: "API Tester",
        oidc_sub: "api-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other_user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-api-#{System.unique_integer([:positive])}@example.com",
        name: "Other API Tester",
        oidc_sub: "other-api-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    conn =
      build_conn()
      |> init_test_session(%{user_id: user.id})
      |> put_req_header("accept", "application/json")

    %{conn: conn, user: user, other_user: other_user}
  end

  describe "require_auth pipeline" do
    test "returns 401 for unauthenticated request" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/conversations")

      assert json_response(conn, 401)["error"] == "authentication required"
    end
  end

  describe "index" do
    test "lists conversations for current user", %{conn: conn, user: user} do
      {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat 1"})
      {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat 2"})

      conn = get(conn, ~p"/api/conversations")
      assert %{"data" => conversations} = json_response(conn, 200)
      assert length(conversations) == 2
    end

    test "supports limit and offset params", %{conn: conn, user: user} do
      for i <- 1..3 do
        {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat #{i}"})
      end

      conn = get(conn, ~p"/api/conversations?limit=1&offset=0")
      assert %{"data" => conversations} = json_response(conn, 200)
      assert length(conversations) == 1
    end

    test "handles non-numeric limit gracefully", %{conn: conn, user: user} do
      {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat"})

      conn = get(conn, ~p"/api/conversations?limit=abc&offset=xyz")
      assert %{"data" => _conversations} = json_response(conn, 200)
    end

    test "clamps limit to maximum", %{conn: conn, user: user} do
      {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat"})

      conn = get(conn, ~p"/api/conversations?limit=999999")
      assert %{"data" => _conversations} = json_response(conn, 200)
    end

    test "handles negative offset gracefully", %{conn: conn, user: user} do
      {:ok, _} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Chat"})

      # Negative values fall through to default
      conn = get(conn, ~p"/api/conversations?offset=-1")
      assert %{"data" => _conversations} = json_response(conn, 200)
    end
  end

  describe "create" do
    test "creates a new conversation", %{conn: conn} do
      conn = post(conn, ~p"/api/conversations", %{title: "My New Chat"})
      assert %{"data" => conversation} = json_response(conn, 201)
      assert conversation["title"] == "My New Chat"
      assert conversation["status"] == "active"
    end
  end

  describe "show" do
    test "returns conversation with messages", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Detail"})
      {:ok, _} = Liteskill.Chat.send_message(conv.id, user.id, "Hello!")

      conn = get(conn, ~p"/api/conversations/#{conv.id}")
      assert %{"data" => conversation} = json_response(conn, 200)
      assert conversation["title"] == "Detail"
      assert length(conversation["messages"]) == 1
    end

    test "returns 404 for another user's conversation", %{user: user, other_user: other} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Private"})

      conn =
        build_conn()
        |> init_test_session(%{user_id: other.id})
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/conversations/#{conv.id}")

      assert json_response(conn, 404)["error"] == "not found"
    end
  end

  describe "send_message" do
    test "adds a message to a conversation", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})

      conn = post(conn, ~p"/api/conversations/#{conv.id}/messages", %{content: "Hello!"})
      assert %{"data" => message} = json_response(conn, 201)
      assert message["role"] == "user"
      assert message["content"] == "Hello!"
    end

    test "returns error for archived conversation", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Liteskill.Chat.archive_conversation(conv.id, user.id)

      conn = post(conn, ~p"/api/conversations/#{conv.id}/messages", %{content: "Hello!"})
      assert json_response(conn, 422)
    end
  end

  describe "fork" do
    test "forks a conversation", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Liteskill.Chat.send_message(conv.id, user.id, "Message 1")

      conn = post(conn, ~p"/api/conversations/#{conv.id}/fork", %{at_position: "1"})
      assert %{"data" => fork} = json_response(conn, 201)
      assert fork["parent_conversation_id"] == conv.id
    end

    test "returns 404 for nonexistent conversation", %{conn: conn} do
      conn = post(conn, ~p"/api/conversations/#{Ecto.UUID.generate()}/fork", %{at_position: "1"})
      assert json_response(conn, 404)
    end

    test "handles non-integer at_position gracefully", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Fork Test"})
      {:ok, _} = Liteskill.Chat.send_message(conv.id, user.id, "Message 1")

      conn = post(conn, ~p"/api/conversations/#{conv.id}/fork", %{at_position: "abc"})
      assert %{"data" => fork} = json_response(conn, 201)
      assert fork["parent_conversation_id"] == conv.id
    end
  end

  describe "grant_access" do
    test "grants access to another user", %{conn: conn, user: user, other_user: other} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})

      conn =
        post(conn, ~p"/api/conversations/#{conv.id}/acls", %{user_id: other.id, role: "member"})

      assert %{"data" => acl} = json_response(conn, 201)
      assert acl["user_id"] == other.id
      assert acl["role"] == "manager"
    end

    test "returns forbidden for non-owner", %{user: user, other_user: other} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})

      conn =
        build_conn()
        |> init_test_session(%{user_id: other.id})
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/conversations/#{conv.id}/acls", %{user_id: user.id})

      assert json_response(conn, 403)["error"] == "forbidden"
    end
  end

  describe "revoke_access" do
    test "revokes access from a user", %{conn: conn, user: user, other_user: other} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Liteskill.Chat.grant_conversation_access(conv.id, user.id, other.id)

      conn = delete(conn, ~p"/api/conversations/#{conv.id}/acls/#{other.id}")
      assert response(conn, 204)
    end

    test "returns error when revoking owner", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})

      conn = delete(conn, ~p"/api/conversations/#{conv.id}/acls/#{user.id}")
      assert json_response(conn, 422)
    end
  end

  describe "leave" do
    test "user can leave a shared conversation", %{user: user, other_user: other} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})
      {:ok, _} = Liteskill.Chat.grant_conversation_access(conv.id, user.id, other.id)

      conn =
        build_conn()
        |> init_test_session(%{user_id: other.id})
        |> put_req_header("accept", "application/json")
        |> delete(~p"/api/conversations/#{conv.id}/membership")

      assert response(conn, 204)
    end

    test "owner cannot leave", %{conn: conn, user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id})

      conn = delete(conn, ~p"/api/conversations/#{conv.id}/membership")
      assert json_response(conn, 422)
    end
  end
end
