defmodule LiteskillWeb.OpenRouterController do
  @moduledoc """
  Handles the OpenRouter OAuth PKCE flow: redirect to OpenRouter and process the callback.

  Supports two callback modes:
  - **State-based** (single-user/desktop): The LiveView generates the PKCE pair and
    stores it in the ETS StateStore keyed by a state token. Always renders static HTML
    ("close this tab") and relies on PubSub to update the LiveView.
  - **Session-based** (multi-user server): `start/2` stores the PKCE verifier in the
    session, redirects to OpenRouter, and `callback/2` reads from the session.
  """

  use LiteskillWeb, :controller

  plug LiteskillWeb.Plugs.Auth, :fetch_current_user

  alias Liteskill.Accounts
  alias Liteskill.LlmProviders
  alias Liteskill.OpenRouter

  @provider_name "OpenRouter"
  @pubsub Liteskill.PubSub

  def start(conn, params) do
    case conn.assigns.current_user do
      nil ->
        redirect(conn, to: ~p"/login")

      _user ->
        {verifier, challenge} = OpenRouter.generate_pkce()
        callback_url = LiteskillWeb.Endpoint.url() <> ~p"/auth/openrouter/callback"

        return_to = validate_return_path(params["return_to"])

        conn
        |> put_session(:openrouter_code_verifier, verifier)
        |> put_session(:openrouter_return_to, return_to)
        |> redirect(external: OpenRouter.auth_url(callback_url, challenge))
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    # State-based lookup from ETS. Used by both web and desktop flows.
    case OpenRouter.StateStore.fetch_and_delete(state) do
      {:ok, %{code_verifier: verifier, user_id: user_id, return_to: return_to}} ->
        callback_state(conn, code, verifier, user_id, return_to)

      :error ->
        # State not found or expired — fall through to session-based flow
        callback_session(conn, code)
    end
  end

  def callback(conn, %{"code" => code}) do
    callback_session(conn, code)
  end

  def callback(conn, _params) do
    return_to = get_session(conn, :openrouter_return_to) || "/"

    conn
    |> delete_session(:openrouter_code_verifier)
    |> delete_session(:openrouter_return_to)
    |> put_flash(:error, "OpenRouter authorization was cancelled or failed.")
    |> redirect(to: return_to)
  end

  # --- State-based flow (web + desktop) ---

  defp callback_state(conn, code, verifier, user_id, return_to) do
    case Accounts.get_user(user_id) do
      nil ->
        desktop_respond(conn, 400, :error)

      user ->
        case OpenRouter.exchange_code(code, verifier) do
          {:ok, key} ->
            handle_state_upsert(conn, user, key, return_to)

          {:error, msg} ->
            respond_error(conn, return_to, "OpenRouter: #{msg}")
        end
    end
  end

  defp handle_state_upsert(conn, user, key, _return_to) do
    case do_upsert(user, key) do
      {:ok, _action} ->
        Phoenix.PubSub.broadcast(@pubsub, openrouter_topic(user.id), :openrouter_connected)
        desktop_respond(conn, 200, :success)

      # coveralls-ignore-start — defensive: provider attrs are always valid
      {:error, _} ->
        desktop_respond(conn, 200, :error)
        # coveralls-ignore-stop
    end
  end

  defp respond_error(conn, _return_to, _msg) do
    desktop_respond(conn, 200, :error)
  end

  # --- Session-based flow (web mode) ---

  defp callback_session(conn, code) do
    verifier = get_session(conn, :openrouter_code_verifier)
    return_to = get_session(conn, :openrouter_return_to) || "/"

    conn =
      conn
      |> delete_session(:openrouter_code_verifier)
      |> delete_session(:openrouter_return_to)

    user = conn.assigns.current_user

    if is_nil(user) or is_nil(verifier) do
      conn
      |> put_flash(:error, "OpenRouter authorization failed. Please try again.")
      |> redirect(to: return_to)
    else
      case OpenRouter.exchange_code(code, verifier) do
        {:ok, key} ->
          upsert_provider(conn, user, key, return_to)

        {:error, msg} ->
          conn
          |> put_flash(:error, "OpenRouter: #{msg}")
          |> redirect(to: return_to)
      end
    end
  end

  # --- Web mode: upsert + flash + redirect ---

  defp upsert_provider(conn, user, key, return_to) do
    case do_upsert(user, key) do
      {:ok, :created} ->
        conn
        |> put_flash(:info, "OpenRouter connected successfully!")
        |> redirect(to: return_to)

      {:ok, :updated} ->
        conn
        |> put_flash(:info, "OpenRouter API key updated!")
        |> redirect(to: return_to)

      # coveralls-ignore-start — defensive: provider attrs are always valid
      {:error, _} ->
        conn
        |> put_flash(:error, "Failed to save OpenRouter provider.")
        |> redirect(to: return_to)

        # coveralls-ignore-stop
    end
  end

  # --- Shared upsert logic ---

  defp do_upsert(user, key) do
    case LlmProviders.get_provider_by_name(@provider_name, user.id) do
      nil ->
        case LlmProviders.create_provider(%{
               name: @provider_name,
               provider_type: "openrouter",
               api_key: key,
               instance_wide: true,
               user_id: user.id
             }) do
          {:ok, provider} ->
            {:ok, :created, provider}

          # coveralls-ignore-start — defensive: provider attrs are always valid
          {:error, changeset} ->
            {:error, changeset}
            # coveralls-ignore-stop
        end

      existing ->
        case LlmProviders.update_provider_record(existing, %{api_key: key, status: "active"}) do
          {:ok, provider} ->
            {:ok, :updated, provider}

          # coveralls-ignore-start — defensive: provider attrs are always valid
          {:error, changeset} ->
            {:error, changeset}
            # coveralls-ignore-stop
        end
    end
    |> normalize_result()
  end

  defp normalize_result({:ok, action, _provider}), do: {:ok, action}
  # coveralls-ignore-start — defensive: only reached if provider attrs invalid
  defp normalize_result({:error, _} = err), do: err
  # coveralls-ignore-stop

  # --- Helpers ---

  @doc false
  def openrouter_topic(user_id), do: "openrouter:#{user_id}"

  defp validate_return_path("//" <> _), do: "/"

  defp validate_return_path("/" <> _ = path) do
    case URI.parse(path) do
      %URI{host: nil, scheme: nil} -> path
      # coveralls-ignore-next-line
      _ -> "/"
    end
  end

  defp validate_return_path(_), do: "/"

  @desktop_success_html "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Liteskill</title></head>" <>
                          "<body style=\"display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;font-family:system-ui,sans-serif;background:#1d232a;color:#a6adba\">" <>
                          "<div style=\"text-align:center;max-width:400px\">" <>
                          "<h1 style=\"font-size:1.5rem;color:#22c55e\">OpenRouter connected!</h1>" <>
                          "<p style=\"margin-top:1rem;opacity:0.7\">You can close this browser tab and return to the app.</p>" <>
                          "</div></body></html>"

  @desktop_error_html "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Liteskill</title></head>" <>
                        "<body style=\"display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;font-family:system-ui,sans-serif;background:#1d232a;color:#a6adba\">" <>
                        "<div style=\"text-align:center;max-width:400px\">" <>
                        "<h1 style=\"font-size:1.5rem;color:#ef4444\">OpenRouter authorization failed</h1>" <>
                        "<p style=\"margin-top:1rem;opacity:0.7\">You can close this browser tab and return to the app.</p>" <>
                        "</div></body></html>"

  defp desktop_respond(conn, status, :success) do
    conn |> put_resp_content_type("text/html") |> send_resp(status, @desktop_success_html)
  end

  defp desktop_respond(conn, status, :error) do
    conn |> put_resp_content_type("text/html") |> send_resp(status, @desktop_error_html)
  end
end
