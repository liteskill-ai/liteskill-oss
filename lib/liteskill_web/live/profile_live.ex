defmodule LiteskillWeb.ProfileLive do
  @moduledoc """
  Profile components and event handlers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :html

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.Groups

  @profile_actions [:info, :password, :admin_servers, :admin_users, :admin_groups]
  @admin_actions [:admin_servers, :admin_users, :admin_groups]

  def profile_action?(action), do: action in @profile_actions

  def profile_assigns do
    [
      password_form: to_form(%{"current" => "", "new" => "", "confirm" => ""}, as: :password),
      password_error: nil,
      password_success: false,
      profile_users: [],
      profile_groups: [],
      group_detail: nil,
      group_members: []
    ]
  end

  def apply_profile_action(socket, action, user) do
    if action in @admin_actions && !User.admin?(user) do
      Phoenix.LiveView.push_navigate(socket, to: ~p"/profile")
    else
      load_tab_data(socket, action)
    end
  end

  defp load_tab_data(socket, :admin_users) do
    Phoenix.Component.assign(socket,
      profile_users: Accounts.list_users(),
      page_title: "User Management"
    )
  end

  defp load_tab_data(socket, :admin_groups) do
    Phoenix.Component.assign(socket,
      profile_groups: Groups.list_all_groups(),
      page_title: "Group Management"
    )
  end

  defp load_tab_data(socket, :admin_servers) do
    Phoenix.Component.assign(socket, page_title: "Server Management")
  end

  defp load_tab_data(socket, :password) do
    Phoenix.Component.assign(socket,
      page_title: "Change Password",
      password_error: nil,
      password_success: false
    )
  end

  defp load_tab_data(socket, _action) do
    Phoenix.Component.assign(socket, page_title: "Profile")
  end

  # --- Public component ---

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, required: true
  attr :password_form, :any, required: true
  attr :password_error, :string
  attr :password_success, :boolean
  attr :profile_users, :list, default: []
  attr :profile_groups, :list, default: []
  attr :group_detail, :any
  attr :group_members, :list, default: []

  def profile(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center gap-2">
        <button
          :if={!@sidebar_open}
          phx-click="toggle_sidebar"
          class="btn btn-circle btn-ghost btn-sm"
        >
          <.icon name="hero-bars-3-micro" class="size-5" />
        </button>
        <h1 class="text-lg font-semibold">Profile</h1>
      </div>
    </header>

    <div class="border-b border-base-300 px-4 flex-shrink-0">
      <div class="flex gap-1 overflow-x-auto" role="tablist">
        <.tab_link label="Info" to={~p"/profile"} active={@live_action == :info} />
        <.tab_link label="Password" to={~p"/profile/password"} active={@live_action == :password} />
        <.tab_link
          :if={User.admin?(@current_user)}
          label="Server Management"
          to={~p"/profile/admin/servers"}
          active={@live_action == :admin_servers}
        />
        <.tab_link
          :if={User.admin?(@current_user)}
          label="Users"
          to={~p"/profile/admin/users"}
          active={@live_action == :admin_users}
        />
        <.tab_link
          :if={User.admin?(@current_user)}
          label="Groups"
          to={~p"/profile/admin/groups"}
          active={@live_action == :admin_groups}
        />
      </div>
    </div>

    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl mx-auto">
        {render_tab(assigns)}
      </div>
    </div>
    """
  end

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "tab tab-bordered whitespace-nowrap",
        @active && "tab-active"
      ]}
    >
      {@label}
    </.link>
    """
  end

  # --- Info Tab ---

  defp render_tab(%{live_action: :info} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Account Information</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Name" value={@current_user.name || "—"} />
            <.info_row label="Email" value={@current_user.email} />
            <.info_row label="Sign-on Source" value={sign_on_source(@current_user)} />
            <div>
              <div class="text-sm text-base-content/60 mb-1">Role</div>
              <span class={[
                "badge",
                User.admin?(@current_user) && "badge-primary",
                !User.admin?(@current_user) && "badge-neutral"
              ]}>
                {String.capitalize(@current_user.role)}
              </span>
            </div>
            <.info_row
              label="Member Since"
              value={Calendar.strftime(@current_user.inserted_at, "%B %d, %Y")}
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Accent Color</h2>
          <div class="flex flex-wrap gap-3">
            <%= for color <- User.accent_colors() do %>
              <button
                phx-click="set_accent_color"
                phx-value-color={color}
                class={[
                  "w-10 h-10 rounded-full border-2 border-base-300 transition-all",
                  accent_swatch_bg(color),
                  User.accent_color(@current_user) == color &&
                    "ring-2 ring-offset-2 ring-offset-base-100 ring-base-content scale-110"
                ]}
                title={color_label(color)}
              />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Password Tab ---

  defp render_tab(%{live_action: :password} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title mb-4">Change Password</h2>
        <.form for={@password_form} phx-submit="change_password" class="space-y-4 max-w-sm">
          <div class="form-control">
            <label class="label"><span class="label-text">Current Password</span></label>
            <input
              type="password"
              name="password[current]"
              class="input input-bordered w-full"
              required
            />
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">New Password</span></label>
            <input
              type="password"
              name="password[new]"
              class="input input-bordered w-full"
              required
              minlength="12"
            />
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Confirm New Password</span></label>
            <input
              type="password"
              name="password[confirm]"
              class="input input-bordered w-full"
              required
              minlength="12"
            />
          </div>
          <p :if={@password_error} class="text-error text-sm">{@password_error}</p>
          <p :if={@password_success} class="text-success text-sm">Password changed successfully.</p>
          <button type="submit" class="btn btn-primary">Update Password</button>
        </.form>
      </div>
    </div>
    """
  end

  # --- Server Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_servers} = assigns) do
    llm_config = Application.get_env(:liteskill, Liteskill.LLM, [])
    repo_config = Liteskill.Repo.config()
    oban_config = Application.get_env(:liteskill, Oban, [])
    oidc_config = Application.get_env(:ueberauth, Ueberauth.Strategy.OIDCC, [])

    assigns =
      assigns
      |> assign(:llm_config, llm_config)
      |> assign(:repo_config, repo_config)
      |> assign(:oban_config, oban_config)
      |> assign(:oidc_config, oidc_config)

    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">LLM Configuration</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Model ID" value={@llm_config[:model_id] || "—"} />
            <.info_row label="Bedrock Region" value={@llm_config[:bedrock_region] || "—"} />
            <.info_row
              label="Bearer Token"
              value={if @llm_config[:bedrock_bearer_token], do: "••••••••", else: "Not set"}
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Database</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Host" value={to_string(@repo_config[:hostname] || "—")} />
            <.info_row label="Port" value={to_string(@repo_config[:port] || 5432)} />
            <.info_row label="Database" value={to_string(@repo_config[:database] || "—")} />
            <.info_row label="Pool Size" value={to_string(@repo_config[:pool_size] || "—")} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">OIDC / SSO</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Issuer" value={@oidc_config[:issuer] || "Not configured"} />
            <.info_row label="Client ID" value={@oidc_config[:client_id] || "Not configured"} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Job Queues (Oban)</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <%= for {queue, limit} <- @oban_config[:queues] || [] do %>
              <.info_row label={to_string(queue)} value={"Concurrency: #{limit}"} />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- User Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_users} = assigns) do
    ~H"""
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
                      User.admin?(user) && "badge-primary",
                      !User.admin?(user) && "badge-neutral"
                    ]}>
                      {String.capitalize(user.role)}
                    </span>
                  </td>
                  <td class="text-sm text-base-content/60">
                    {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
                  </td>
                  <td>
                    <%= if user.email != User.admin_email() do %>
                      <%= if User.admin?(user) do %>
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
                    <% else %>
                      <span class="text-xs text-base-content/40">Root</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Group Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_groups} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Groups</h2>
            <form phx-submit="create_group" class="flex gap-2">
              <input
                type="text"
                name="name"
                placeholder="New group name"
                class="input input-bordered input-sm"
                required
              />
              <button type="submit" class="btn btn-primary btn-sm">Create</button>
            </form>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Members</th>
                  <th>Created By</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for group <- @profile_groups do %>
                  <tr>
                    <td>{group.name}</td>
                    <td>{length(group.memberships)}</td>
                    <td class="text-sm text-base-content/60">
                      {group.creator && group.creator.email}
                    </td>
                    <td class="flex gap-1">
                      <button
                        phx-click="view_group"
                        phx-value-id={group.id}
                        class="btn btn-ghost btn-xs"
                      >
                        View
                      </button>
                      <button
                        phx-click="admin_delete_group"
                        phx-value-id={group.id}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Delete
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div :if={@group_detail} class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{@group_detail.name} — Members</h2>
            <form phx-submit="admin_add_member" class="flex gap-2">
              <input
                type="email"
                name="email"
                placeholder="User email"
                class="input input-bordered input-sm"
                required
              />
              <button type="submit" class="btn btn-primary btn-sm">Add</button>
            </form>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Role</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for member <- @group_members do %>
                  <tr>
                    <td>{member.user.email}</td>
                    <td>
                      <span class="badge badge-sm badge-neutral">{member.role}</span>
                    </td>
                    <td>
                      <button
                        phx-click="admin_remove_member"
                        phx-value-user-id={member.user_id}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Remove
                      </button>
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

  # --- Helpers ---

  defp info_row(assigns) do
    ~H"""
    <div>
      <div class="text-sm text-base-content/60 mb-1">{@label}</div>
      <div class="font-medium">{@value}</div>
    </div>
    """
  end

  defp sign_on_source(%User{oidc_sub: nil}), do: "Local (password)"
  defp sign_on_source(%User{oidc_issuer: issuer}), do: "SSO (#{issuer})"

  defp accent_swatch_bg("pink"), do: "bg-pink-500"
  defp accent_swatch_bg("red"), do: "bg-red-500"
  defp accent_swatch_bg("orange"), do: "bg-orange-500"
  defp accent_swatch_bg("yellow"), do: "bg-yellow-400"
  defp accent_swatch_bg("green"), do: "bg-green-500"
  defp accent_swatch_bg("cyan"), do: "bg-cyan-500"
  defp accent_swatch_bg("blue"), do: "bg-blue-500"
  defp accent_swatch_bg("royal-blue"), do: "bg-blue-700"
  defp accent_swatch_bg("purple"), do: "bg-violet-500"
  defp accent_swatch_bg("brown"), do: "bg-amber-800"
  defp accent_swatch_bg("black"), do: "bg-neutral-900"

  defp color_label(color), do: color |> String.replace("-", " ") |> String.capitalize()

  # --- Event Handlers (called from ChatLive) ---

  def handle_event("change_password", %{"password" => params}, socket) do
    current = params["current"]
    new_pass = params["new"]
    confirm = params["confirm"]

    cond do
      new_pass != confirm ->
        {:noreply,
         Phoenix.Component.assign(socket,
           password_error: "Passwords do not match",
           password_success: false
         )}

      String.length(new_pass) < 12 ->
        {:noreply,
         Phoenix.Component.assign(socket,
           password_error: "New password must be at least 12 characters",
           password_success: false
         )}

      true ->
        case Accounts.change_password(socket.assigns.current_user, current, new_pass) do
          {:ok, user} ->
            {:noreply,
             socket
             |> Phoenix.Component.assign(
               current_user: user,
               password_error: nil,
               password_success: true,
               password_form:
                 to_form(%{"current" => "", "new" => "", "confirm" => ""}, as: :password)
             )}

          {:error, :invalid_current_password} ->
            {:noreply,
             Phoenix.Component.assign(socket,
               password_error: "Current password is incorrect",
               password_success: false
             )}

          {:error, _changeset} ->
            {:noreply,
             Phoenix.Component.assign(socket,
               password_error: "Failed to change password",
               password_success: false
             )}
        end
    end
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    if User.admin?(socket.assigns.current_user) do
      Accounts.update_user_role(id, "admin")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    if User.admin?(socket.assigns.current_user) do
      Accounts.update_user_role(id, "user")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    user_id = socket.assigns.current_user.id
    Groups.create_group(name, user_id)
    {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
  end

  def handle_event("admin_delete_group", %{"id" => id}, socket) do
    if User.admin?(socket.assigns.current_user) do
      Groups.admin_delete_group(id)

      socket =
        if socket.assigns.group_detail && socket.assigns.group_detail.id == id do
          Phoenix.Component.assign(socket, group_detail: nil, group_members: [])
        else
          socket
        end

      {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_group", %{"id" => id}, socket) do
    case Groups.admin_get_group(id) do
      {:ok, group} ->
        members = Groups.admin_list_members(id)
        {:noreply, Phoenix.Component.assign(socket, group_detail: group, group_members: members)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("admin_add_member", %{"email" => email}, socket) do
    if User.admin?(socket.assigns.current_user) do
      group = socket.assigns.group_detail

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "User not found")}

        user ->
          case Groups.admin_add_member(group.id, user.id, "member") do
            {:ok, _} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 group_members: Groups.admin_list_members(group.id)
               )}

            {:error, _} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to add member")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("admin_remove_member", %{"user-id" => user_id}, socket) do
    if User.admin?(socket.assigns.current_user) do
      group = socket.assigns.group_detail
      Groups.admin_remove_member(group.id, user_id)

      {:noreply,
       Phoenix.Component.assign(socket, group_members: Groups.admin_list_members(group.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_accent_color", %{"color" => color}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_preferences(user, %{"accent_color" => color}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(current_user: updated_user)
         |> Phoenix.LiveView.push_event("set-accent", %{color: color})}

      {:error, _} ->
        {:noreply, socket}
    end
  end
end
