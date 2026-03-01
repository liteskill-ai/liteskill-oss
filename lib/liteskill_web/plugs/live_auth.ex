defmodule LiteskillWeb.Plugs.LiveAuth do
  @moduledoc """
  LiveView on_mount hooks for authentication.

  Used in live_session to protect LiveView routes.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.SingleUser

  @touch_throttle_seconds 60

  def on_mount(:require_authenticated, _params, session, socket) do
    if SingleUser.enabled?() do
      if SingleUser.setup_needed?() do
        {:halt, redirect(socket, to: "/setup")}
      else
        {:cont, assign(socket, :current_user, SingleUser.auto_user())}
      end
    else
      case session["session_token"] do
        nil ->
          {:halt, redirect(socket, to: "/login")}

        token ->
          case Accounts.validate_session_with_user(token) do
            nil ->
              {:halt, redirect(socket, to: "/login")}

            {session_record, user} ->
              maybe_touch_session(session_record)

              if User.setup_required?(user) do
                {:halt, redirect(socket, to: "/setup")}
              else
                {:cont, assign(socket, :current_user, user)}
              end
          end
      end
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    if SingleUser.enabled?() do
      if SingleUser.setup_needed?() do
        {:halt, redirect(socket, to: "/setup")}
      else
        {:cont, assign(socket, :current_user, SingleUser.auto_user())}
      end
    else
      case session["session_token"] do
        nil ->
          {:halt, redirect(socket, to: "/login")}

        token ->
          case Accounts.validate_session_with_user(token) do
            nil ->
              {:halt, redirect(socket, to: "/login")}

            {session_record, user} ->
              maybe_touch_session(session_record)

              if Liteskill.Rbac.has_any_admin_permission?(user.id) do
                {:cont, assign(socket, :current_user, user)}
              else
                {:halt, redirect(socket, to: "/")}
              end
          end
      end
    end
  end

  def on_mount(:require_setup_needed, _params, _session, socket) do
    if SingleUser.enabled?() do
      if SingleUser.setup_needed?() do
        {:cont, assign(socket, :current_user, SingleUser.auto_user())}
      else
        {:halt, redirect(socket, to: "/")}
      end
    else
      admin = Accounts.get_user_by_email(User.admin_email())

      if admin && User.setup_required?(admin) do
        {:cont, assign(socket, :current_user, admin)}
      else
        {:halt, redirect(socket, to: "/")}
      end
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    if SingleUser.enabled?() do
      if SingleUser.setup_needed?() do
        {:halt, redirect(socket, to: "/setup")}
      else
        {:halt, redirect(socket, to: "/")}
      end
    else
      # If admin account needs setup, redirect to setup regardless of auth
      admin = Accounts.get_user_by_email(User.admin_email())

      if admin && User.setup_required?(admin) do
        {:halt, redirect(socket, to: "/setup")}
      else
        case session["session_token"] do
          nil ->
            {:cont, assign(socket, :current_user, nil)}

          token ->
            case Accounts.validate_session_with_user(token) do
              nil ->
                {:cont, assign(socket, :current_user, nil)}

              {_session, _user} ->
                {:halt, redirect(socket, to: "/")}
            end
        end
      end
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
