defmodule LiteskillWeb.SessionController do
  @moduledoc """
  Bridge controller for LiveView authentication.

  LiveView cannot set session directly, so auth LiveViews redirect here
  with a signed token to establish the session.
  """

  use LiteskillWeb, :controller

  alias Liteskill.Accounts
  alias LiteskillWeb.Plugs.SessionHelpers

  @max_age 60

  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(LiteskillWeb.Endpoint, "user_session", token, max_age: @max_age) do
      {:ok, user_id} ->
        conn_info = SessionHelpers.conn_info(conn)
        {:ok, session} = Accounts.create_session(user_id, conn_info)

        Accounts.log_auth_event(%{
          event_type: "login_success",
          user_id: user_id,
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "liveview_token"}
        })

        conn
        |> configure_session(renew: true)
        |> put_session(:session_token, session.id)
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Session expired, please try again.")
        |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    session_token = get_session(conn, :session_token)

    if session_token do
      case Accounts.delete_and_return_session(session_token) do
        {:ok, session} ->
          conn_info = SessionHelpers.conn_info(conn)

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
    |> clear_session()
    |> redirect(to: "/login")
  end
end
