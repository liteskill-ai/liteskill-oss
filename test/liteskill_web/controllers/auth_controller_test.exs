defmodule LiteskillWeb.AuthControllerTest do
  use LiteskillWeb.ConnCase, async: true

  alias Liteskill.Accounts
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Auth.Info

  describe "callback/2" do
    test "creates user and sets session on successful auth", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "oidc-sub-#{System.unique_integer([:positive])}",
        info: %Info{
          email: "user-#{System.unique_integer([:positive])}@example.com",
          name: "Test User",
          image: "https://example.com/avatar.png"
        },
        extra: %Extra{
          raw_info: %{
            userinfo: %{"iss" => "https://idp.example.com", "email_verified" => true}
          }
        }
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> post("/auth/oidc/callback")

      assert %{"ok" => true, "user_id" => user_id} = json_response(conn, 200)
      assert user_id

      user = Accounts.get_user!(user_id)
      assert user.email == auth.info.email
    end

    test "returns error on auth failure", %{conn: conn} do
      failure = %Ueberauth.Failure{
        provider: :oidc,
        errors: [%Ueberauth.Failure.Error{message: "invalid token"}]
      }

      conn =
        conn
        |> assign(:ueberauth_failure, failure)
        |> post("/auth/oidc/callback")

      assert %{"error" => "authentication failed"} = json_response(conn, 401)
    end

    test "returns error when user creation fails due to changeset", %{conn: conn} do
      # Missing email will cause changeset validation failure
      auth = %Ueberauth.Auth{
        uid: "oidc-sub-changeset-#{System.unique_integer([:positive])}",
        info: %Info{
          email: nil,
          name: "Test User",
          image: nil
        },
        extra: %Extra{
          raw_info: %{
            userinfo: %{"iss" => "https://idp.example.com"}
          }
        }
      }

      conn =
        conn
        |> assign(:ueberauth_auth, auth)
        |> post("/auth/oidc/callback")

      assert %{"error" => "failed to authenticate"} = json_response(conn, 422)
    end
  end

  describe "logout/2" do
    test "clears session and redirects to login", %{conn: conn} do
      conn = delete(conn, "/auth/logout")
      assert redirected_to(conn) == "/login"
    end
  end
end
