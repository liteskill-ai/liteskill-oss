defmodule LiteskillWeb.SamlAuthController do
  @moduledoc """
  Handles the post-SAML-authentication callback. Samly redirects here after
  a successful SAML assertion. We read the assertion, find or create the user,
  create an app session, and redirect to the main app.
  """

  use LiteskillWeb, :controller

  alias Liteskill.Accounts
  alias LiteskillWeb.Plugs.SessionHelpers

  @email_attributes [
    "email",
    "Email",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
    "http://schemas.xmlsoap.org/claims/EmailAddress",
    "urn:oid:0.9.2342.19200300.100.1.3"
  ]

  @name_attributes [
    "displayName",
    "name",
    "Name",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name",
    "http://schemas.xmlsoap.org/claims/CommonName",
    "urn:oid:2.16.840.1.113730.3.1.241"
  ]

  def callback(conn, _params) do
    case Samly.get_active_assertion(conn) do
      %Samly.Assertion{} = assertion ->
        handle_assertion(conn, assertion)

      _ ->
        conn
        |> put_flash(:error, "SAML authentication failed")
        |> redirect(to: ~p"/login")
    end
  end

  defp handle_assertion(conn, assertion) do
    attrs = assertion.attributes
    name_id = assertion.subject.name

    email = find_attribute(attrs, @email_attributes) || name_id
    name = find_attribute(attrs, @name_attributes)

    issuer =
      case assertion do
        %{issuer: issuer} when is_binary(issuer) and issuer != "" -> issuer
        _ -> "saml"
      end

    user_attrs = %{
      email: email,
      name: name,
      saml_name_id: name_id,
      saml_issuer: issuer
    }

    conn_info = SessionHelpers.conn_info(conn)

    case Accounts.find_or_create_from_saml(user_attrs) do
      {:ok, user} ->
        {:ok, session} = Accounts.create_session(user.id, conn_info)
        new_registration? = recently_created?(user)

        Accounts.log_auth_event(%{
          event_type: if(new_registration?, do: "registration_success", else: "login_success"),
          user_id: user.id,
          ip_address: conn_info.ip_address,
          user_agent: conn_info.user_agent,
          metadata: %{"method" => "saml"}
        })

        conn
        |> put_session(:session_token, session.id)
        |> redirect(to: ~p"/")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to create account from SAML assertion")
        |> redirect(to: ~p"/login")
    end
  end

  defp find_attribute(attrs, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        "" -> nil
        value when is_binary(value) -> value
        [value | _] when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp recently_created?(%{inserted_at: inserted_at}) do
    SessionHelpers.recently_created?(inserted_at)
  end
end
