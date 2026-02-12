defmodule LiteskillWeb.SessionController do
  @moduledoc """
  Bridge controller for LiveView authentication.

  LiveView cannot set session directly, so auth LiveViews redirect here
  with a signed token to establish the session.
  """

  use LiteskillWeb, :controller

  @max_age 60

  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(LiteskillWeb.Endpoint, "user_session", token, max_age: @max_age) do
      {:ok, user_id} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user_id)
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Session expired, please try again.")
        |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end
end
