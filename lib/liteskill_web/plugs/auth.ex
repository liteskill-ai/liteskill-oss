defmodule LiteskillWeb.Plugs.Auth do
  @moduledoc """
  Authentication plugs for session-based user loading and access control.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Liteskill.Accounts
  alias Liteskill.SingleUser

  @touch_throttle_seconds 60

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

  defp maybe_touch_session(%{last_active_at: last_active_at} = session) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    elapsed = DateTime.diff(now, last_active_at, :second)

    if elapsed >= @touch_throttle_seconds do
      Accounts.touch_session(session)
    end
  end
end
