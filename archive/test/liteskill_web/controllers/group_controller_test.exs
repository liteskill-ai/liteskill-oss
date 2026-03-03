defmodule LiteskillWeb.GroupControllerTest do
  use LiteskillWeb.ConnCase, async: true

  alias Liteskill.Groups

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "group-api-#{System.unique_integer([:positive])}@example.com",
        name: "Group API Tester",
        oidc_sub: "group-api-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other_user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-group-#{System.unique_integer([:positive])}@example.com",
        name: "Other Group User",
        oidc_sub: "other-group-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    conn =
      build_conn()
      |> init_authenticated_session(user)
      |> put_req_header("accept", "application/json")

    %{conn: conn, user: user, other_user: other_user}
  end

  describe "index" do
    test "lists groups for current user", %{conn: conn, user: user} do
      {:ok, _} = Groups.create_group("Group 1", user.id)
      {:ok, _} = Groups.create_group("Group 2", user.id)

      conn = get(conn, ~p"/api/groups")
      assert %{"data" => groups} = json_response(conn, 200)
      assert length(groups) == 2
    end
  end

  describe "create" do
    test "creates a new group", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/groups", %{name: "New Group"})
      assert %{"data" => group} = json_response(conn, 201)
      assert group["name"] == "New Group"
      assert group["created_by"] == user.id
    end
  end

  describe "show" do
    test "returns group for a member", %{conn: conn, user: user} do
      {:ok, group} = Groups.create_group("My Group", user.id)

      conn = get(conn, ~p"/api/groups/#{group.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == group.id
      assert data["name"] == "My Group"
    end

    test "returns 404 for non-member", %{user: user, other_user: other} do
      {:ok, group} = Groups.create_group("Private Group", user.id)

      conn =
        build_conn()
        |> init_authenticated_session(other)
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/groups/#{group.id}")

      assert json_response(conn, 404)
    end
  end

  describe "delete" do
    test "creator can delete group", %{conn: conn, user: user} do
      {:ok, group} = Groups.create_group("To Delete", user.id)

      conn = delete(conn, ~p"/api/groups/#{group.id}")
      assert response(conn, 204)
    end

    test "non-creator cannot delete", %{user: user, other_user: other} do
      {:ok, group} = Groups.create_group("Protected", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)

      conn =
        build_conn()
        |> init_authenticated_session(other)
        |> put_req_header("accept", "application/json")
        |> delete(~p"/api/groups/#{group.id}")

      assert json_response(conn, 403)
    end
  end

  describe "add_member" do
    test "adds member to group", %{conn: conn, user: user, other_user: other} do
      {:ok, group} = Groups.create_group("My Group", user.id)

      conn =
        post(conn, ~p"/api/groups/#{group.id}/members", %{user_id: other.id, role: "member"})

      assert %{"data" => membership} = json_response(conn, 201)
      assert membership["user_id"] == other.id
      assert membership["role"] == "member"
    end

    test "returns forbidden for non-creator", %{user: user, other_user: other} do
      {:ok, group} = Groups.create_group("My Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)

      conn =
        build_conn()
        |> init_authenticated_session(other)
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/groups/#{group.id}/members", %{user_id: user.id})

      assert json_response(conn, 403)
    end
  end

  describe "remove_member" do
    test "removes member from group", %{conn: conn, user: user, other_user: other} do
      {:ok, group} = Groups.create_group("My Group", user.id)
      {:ok, _} = Groups.add_member(group.id, user.id, other.id)

      conn = delete(conn, ~p"/api/groups/#{group.id}/members/#{other.id}")
      assert response(conn, 204)
    end

    test "cannot remove owner", %{conn: conn, user: user} do
      {:ok, group} = Groups.create_group("My Group", user.id)

      conn = delete(conn, ~p"/api/groups/#{group.id}/members/#{user.id}")
      assert json_response(conn, 422)
    end
  end
end
