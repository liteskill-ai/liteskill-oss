defmodule LiteskillWeb.AuthController do
  @moduledoc false
  use LiteskillWeb, :controller

  alias Liteskill.Accounts
  alias LiteskillWeb.Plugs.SessionHelpers

  plug Ueberauth

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    user_attrs = %{
      email: auth.info.email,
      name: auth.info.name,
      avatar_url: auth.info.image,
      oidc_sub: auth.uid,
      oidc_issuer: auth.extra.raw_info.userinfo["iss"] || "unknown",
      oidc_claims: auth.extra.raw_info.userinfo || %{}
    }

    conn_info = SessionHelpers.conn_info(conn)

    case Accounts.find_or_create_from_oidc(user_attrs) do
      {:ok, user} ->
        {:ok, session} = Accounts.create_session(user.id, conn_info)
        new_registration? = recently_created?(user)

        Accounts.log_auth_event(%{
          event_type: if(new_registration?, do: "registration_success", else: "login_success"),
          user_id: user.id,
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "oidc"}
        })

        conn
        |> put_session(:session_token, session.id)
        |> json(%{ok: true, user_id: user.id})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "failed to authenticate"})
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn_info = SessionHelpers.conn_info(conn)

    Accounts.log_auth_event(%{
      event_type: "login_failure",
      ip_address: conn_info.ip_address,
      user_agent: conn_info.user_agent,
      metadata: %{"method" => "oidc"}
    })

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "authentication failed"})
  end

  def logout(conn, _params) do
    session_token = get_session(conn, :session_token)
    conn_info = SessionHelpers.conn_info(conn)

    if session_token do
      case Accounts.delete_and_return_session(session_token) do
        {:ok, session} ->
          Accounts.log_auth_event(%{
            event_type: "logout",
            user_id: session.user_id,
            ip_address: conn_info.ip_address,
            user_agent: conn_info.user_agent
          })

        :error ->
          :ok
      end
    end

    conn
    |> configure_session(drop: true)
    |> json(%{ok: true})
  end

  # A user created within the last 5 seconds during an OIDC callback is a new registration.
  defp recently_created?(%{inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) < 5
  end
end
