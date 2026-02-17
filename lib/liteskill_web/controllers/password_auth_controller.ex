defmodule LiteskillWeb.PasswordAuthController do
  use LiteskillWeb, :controller

  alias Liteskill.Accounts

  def register(conn, params) do
    if Liteskill.Settings.registration_open?() do
      attrs = %{
        email: params["email"],
        name: params["name"],
        password: params["password"]
      }

      case Accounts.register_user(attrs) do
        {:ok, user} ->
          conn
          |> put_session(:user_id, user.id)
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
    email = if email == "admin", do: Accounts.User.admin_email(), else: email

    case Accounts.authenticate_by_email_password(email, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> json(%{data: %{id: user.id, email: user.email, name: user.name}})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid credentials"})
    end
  end
end
