defmodule LiteskillWeb.Plugs.Auth do
  @moduledoc """
  Authentication plugs for session-based user loading and access control.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Liteskill.Accounts
  alias Liteskill.SingleUser
  alias LiteskillWeb.Plugs.SessionHelpers

  def init(action), do: action

  def call(conn, :fetch_current_user), do: fetch_current_user(conn)
  def call(conn, :require_authenticated_user), do: require_authenticated_user(conn)

  def fetch_current_user(conn, _opts \\ []) do
    if SingleUser.enabled?() do
      assign(conn, :current_user, SingleUser.auto_user())
    else
      case get_session(conn, :session_token) do
        nil ->
          assign(conn, :current_user, nil)

        token ->
          case Accounts.validate_session_with_user(token) do
            {session, user} ->
              maybe_touch_session(session)
              assign(conn, :current_user, user)

            nil ->
              conn
              |> delete_session(:session_token)
              |> assign(:current_user, nil)
          end
      end
    end
  end

  def require_authenticated_user(conn, _opts \\ []) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication required"})
      |> halt()
    end
  end

  defp maybe_touch_session(session), do: SessionHelpers.maybe_touch_session(session)
end
