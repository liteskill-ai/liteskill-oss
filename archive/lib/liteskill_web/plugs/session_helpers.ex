defmodule LiteskillWeb.Plugs.SessionHelpers do
  @moduledoc """
  Shared helpers for extracting client metadata from connections
  and session-related utilities used across auth controllers and plugs.
  """

  alias Liteskill.Accounts

  @max_user_agent_length 512
  @touch_throttle_seconds 60

  @doc """
  Extracts `%{ip_address: ..., user_agent: ...}` from the connection.
  """
  def conn_info(conn) do
    %{
      ip_address: client_ip(conn),
      user_agent: client_user_agent(conn)
    }
  end

  @doc """
  Extracts the client IP address from x-forwarded-for header or remote_ip.
  """
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  @doc """
  Extracts the user-agent header, truncated to #{@max_user_agent_length} characters.
  """
  def client_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, @max_user_agent_length)
      [] -> nil
    end
  end

  @doc """
  Returns true if the given `inserted_at` timestamp is within the last 5 seconds.

  Used during OIDC/SAML callbacks to distinguish new registrations from logins.
  """
  def recently_created?(inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) < 5
  end

  @doc """
  Touches the session's `last_active_at` timestamp if enough time has elapsed.

  Throttled to once per #{@touch_throttle_seconds} seconds to avoid excessive DB writes.
  """
  def maybe_touch_session(%{last_active_at: last_active_at} = session) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    elapsed = DateTime.diff(now, last_active_at, :second)

    if elapsed >= @touch_throttle_seconds do
      Accounts.touch_session(session)
    end
  end
end
