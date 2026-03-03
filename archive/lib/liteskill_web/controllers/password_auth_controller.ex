defmodule LiteskillWeb.PasswordAuthController do
  @moduledoc false
  use LiteskillWeb, :controller

  alias Liteskill.Accounts
  alias LiteskillWeb.Plugs.SessionHelpers

  def register(conn, params) do
    if Liteskill.Settings.registration_open?() do
      attrs = %{
        email: params["email"],
        name: params["name"],
        password: params["password"]
      }

      case Accounts.register_user(attrs) do
        {:ok, user} ->
          conn_info = SessionHelpers.conn_info(conn)
          {:ok, session} = Accounts.create_session(user.id, conn_info)

          Accounts.log_auth_event(%{
            event_type: "login_success",
            user_id: user.id,
            ip_address: conn_info.ip_address,
            user_agent: conn_info.user_agent,
            metadata: %{"method" => "registration"}
          })

          conn
          |> put_session(:session_token, session.id)
          |> put_status(:created)
          |> json(%{data: %{id: user.id, email: user.email, name: user.name}})

        {:error, changeset} ->
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
              Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
              end)
            end)

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "validation failed", details: errors})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Registration is currently closed"})
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    conn_info = SessionHelpers.conn_info(conn)

    case Accounts.authenticate_by_email_password(email, password) do
      {:ok, user} ->
        {:ok, session} = Accounts.create_session(user.id, conn_info)

        Accounts.log_auth_event(%{
          event_type: "login_success",
          user_id: user.id,
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "password"}
        })

        conn
        |> put_session(:session_token, session.id)
        |> json(%{data: %{id: user.id, email: user.email, name: user.name}})

      {:error, :invalid_credentials} ->
        # Log failure — resolve user_id by email if possible
        user = Accounts.get_user_by_email(email)

        Accounts.log_auth_event(%{
          event_type: "login_failure",
          user_id: if(user, do: user.id),
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "password", "email" => email}
        })

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid credentials"})
    end
  end
end
