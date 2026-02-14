defmodule LiteskillWeb.PasswordAuthControllerTest do
  use LiteskillWeb.ConnCase, async: true

  @valid_attrs %{
    "email" => "newuser@example.com",
    "name" => "New User",
    "password" => "supersecretpass123"
  }

  describe "register" do
    test "creates user and returns 201 with session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/register", @valid_attrs)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["email"] == "newuser@example.com"
      assert data["name"] == "New User"
      assert data["id"] != nil
      assert get_session(conn, :user_id) == data["id"]
    end

    test "returns error for duplicate email", %{conn: conn} do
      unique = System.unique_integer([:positive])
      attrs = %{@valid_attrs | "email" => "dup-#{unique}@example.com"}

      conn
      |> init_test_session(%{})
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/register", attrs)

      conn2 =
        build_conn()
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/register", attrs)

      assert json_response(conn2, 422)["error"] == "validation failed"
    end

    test "returns error for short password", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/register", %{@valid_attrs | "password" => "short"})

      assert json_response(conn, 422)["error"] == "validation failed"
    end

    test "returns error for missing fields", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/register", %{})

      assert json_response(conn, 422)["error"] == "validation failed"
    end

    test "returns 403 when registration is closed", %{conn: conn} do
      Liteskill.Settings.get()
      Liteskill.Settings.update(%{registration_open: false})

      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/register", @valid_attrs)

      assert json_response(conn, 403)["error"] == "Registration is currently closed"

      # Restore default
      Liteskill.Settings.update(%{registration_open: true})
    end
  end

  describe "login" do
    setup %{conn: conn} do
      unique = System.unique_integer([:positive])
      email = "login-#{unique}@example.com"

      conn
      |> init_test_session(%{})
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/register", %{
        "email" => email,
        "name" => "Login User",
        "password" => "supersecretpass123"
      })

      %{email: email}
    end

    test "authenticates with valid credentials", %{conn: conn, email: email} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/login", %{"email" => email, "password" => "supersecretpass123"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["email"] == email
      assert get_session(conn, :user_id) == data["id"]
    end

    test "returns error for wrong password", %{conn: conn, email: email} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/login", %{"email" => email, "password" => "wrongpassword12"})

      assert json_response(conn, 401)["error"] == "invalid credentials"
    end

    test "returns error for nonexistent email", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_req_header("accept", "application/json")
        |> post(~p"/auth/login", %{"email" => "nobody@example.com", "password" => "doesntmatter1"})

      assert json_response(conn, 401)["error"] == "invalid credentials"
    end
  end
end
