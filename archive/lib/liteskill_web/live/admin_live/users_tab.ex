defmodule LiteskillWeb.AdminLive.UsersTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User

  def assigns do
    [
      profile_users: [],
      invitations: [],
      new_invitation_url: nil,
      temp_password_user_id: nil
    ]
  end

  def load_data(socket) do
    assign(socket,
      profile_users: Accounts.list_users(),
      invitations: Accounts.list_invitations(),
      new_invitation_url: nil,
      page_title: "User Management"
    )
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "admin")
      {:noreply, assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "user")
      {:noreply, assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("show_temp_password_form", %{"id" => id}, socket) do
    {:noreply, assign(socket, temp_password_user_id: id)}
  end

  def handle_event("cancel_temp_password", _params, socket) do
    {:noreply, assign(socket, temp_password_user_id: nil)}
  end

  def handle_event("set_temp_password", %{"user_id" => id, "password" => password}, socket) do
    require_admin(socket, fn ->
      user = Accounts.get_user!(id)

      case Accounts.set_temporary_password(user, password) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             temp_password_user_id: nil,
             profile_users: Accounts.list_users()
           )
           |> put_flash(
             :info,
             "Temporary password set. User must change it on next login."
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("set password", reason)
           )}
      end
    end)
  end

  def handle_event("create_invitation", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      case Accounts.create_invitation(email, socket.assigns.current_user.id) do
        {:ok, invitation} ->
          url = LiteskillWeb.Endpoint.url() <> "/invite/#{invitation.token}"

          {:noreply,
           socket
           |> assign(
             invitations: Accounts.list_invitations(),
             new_invitation_url: url
           )
           |> put_flash(:info, "Invitation created")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("create invitation", reason))}
      end
    end)
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Accounts.revoke_invitation(id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(invitations: Accounts.list_invitations())
           |> put_flash(:info, "Invitation revoked")}

        {:error, :already_used} ->
          {:noreply, put_flash(socket, :error, "Cannot revoke a used invitation")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("revoke invitation", reason))}
      end
    end)
  end

  def render_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Invite User</h2>
          <form phx-submit="create_invitation" class="flex gap-2 items-end">
            <div class="form-control flex-1">
              <input
                type="email"
                name="email"
                placeholder="user@example.com"
                class="input input-bordered input-sm w-full"
                required
              />
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Send Invite</button>
          </form>
          <div
            :if={@new_invitation_url}
            class="alert alert-success mt-3"
          >
            <div class="flex-1">
              <p class="font-medium text-sm">Invitation created! Share this link:</p>
              <div class="flex items-center gap-2 mt-1">
                <code class="text-xs break-all flex-1" id="invite-url">{@new_invitation_url}</code>
                <button
                  phx-click={Phoenix.LiveView.JS.dispatch("phx:copy", to: "#invite-url")}
                  class="btn btn-ghost btn-xs"
                >
                  Copy
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@invitations != []} class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Pending Invitations</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Invited By</th>
                  <th>Expires</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for inv <- @invitations do %>
                  <tr>
                    <td class="font-mono text-sm">{inv.email}</td>
                    <td class="text-sm text-base-content/60">
                      {inv.created_by && inv.created_by.email}
                    </td>
                    <td class="text-sm text-base-content/60">
                      {Calendar.strftime(inv.expires_at, "%Y-%m-%d %H:%M")}
                    </td>
                    <td>{invitation_status_badge(inv)}</td>
                    <td>
                      <button
                        :if={!Liteskill.Accounts.Invitation.used?(inv)}
                        phx-click="revoke_invitation"
                        phx-value-id={inv.id}
                        data-confirm="Revoke this invitation?"
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">User Management</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Email</th>
                  <th>Source</th>
                  <th>Role</th>
                  <th>Created</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for user <- @profile_users do %>
                  <tr>
                    <td>{user.name || "—"}</td>
                    <td class="font-mono text-sm">{user.email}</td>
                    <td>{sign_on_source(user)}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        user.role == "admin" && "badge-primary",
                        user.role != "admin" && "badge-neutral"
                      ]}>
                        {String.capitalize(user.role)}
                      </span>
                    </td>
                    <td class="text-sm text-base-content/60">
                      {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
                    </td>
                    <td class="flex gap-1">
                      <%= if user.email != User.admin_email() do %>
                        <%= if user.role == "admin" do %>
                          <button
                            phx-click="demote_user"
                            phx-value-id={user.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Demote
                          </button>
                        <% else %>
                          <button
                            phx-click="promote_user"
                            phx-value-id={user.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Promote
                          </button>
                        <% end %>
                        <button
                          phx-click="show_temp_password_form"
                          phx-value-id={user.id}
                          class="btn btn-ghost btn-xs"
                        >
                          Set Password
                        </button>
                      <% else %>
                        <span class="text-xs text-base-content/40">Root</span>
                      <% end %>
                    </td>
                  </tr>
                  <tr :if={@temp_password_user_id == user.id}>
                    <td colspan="6">
                      <form
                        phx-submit="set_temp_password"
                        class="flex items-center gap-2 py-2"
                      >
                        <input type="hidden" name="user_id" value={user.id} />
                        <span class="text-sm">
                          Set temporary password for <strong>{user.email}</strong>:
                        </span>
                        <input
                          type="password"
                          name="password"
                          placeholder="Min 12 characters"
                          class="input input-bordered input-sm w-48"
                          required
                          minlength="12"
                        />
                        <button type="submit" class="btn btn-primary btn-sm">Set</button>
                        <button
                          type="button"
                          phx-click="cancel_temp_password"
                          class="btn btn-ghost btn-sm"
                        >
                          Cancel
                        </button>
                      </form>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp sign_on_source(%User{oidc_sub: nil}), do: "Local (password)"
  defp sign_on_source(%User{oidc_issuer: issuer}), do: "SSO (#{issuer})"

  defp invitation_status_badge(inv) do
    alias Liteskill.Accounts.Invitation

    cond do
      Invitation.used?(inv) ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-success">Used</span>))

      Invitation.expired?(inv) ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-warning">Expired</span>))

      true ->
        Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-info">Pending</span>))
    end
  end
end
