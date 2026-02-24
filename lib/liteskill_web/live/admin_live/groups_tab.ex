defmodule LiteskillWeb.AdminLive.GroupsTab do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]
  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]

  alias Liteskill.Accounts
  alias Liteskill.Groups

  def assigns do
    [
      profile_groups: [],
      group_detail: nil,
      group_members: []
    ]
  end

  def load_data(socket) do
    assign(socket,
      profile_groups: Groups.list_all_groups(),
      page_title: "Group Management"
    )
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      Groups.create_group(name, user_id)
      {:noreply, assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("admin_delete_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Groups.admin_delete_group(id)

      socket =
        if socket.assigns.group_detail && socket.assigns.group_detail.id == id do
          assign(socket, group_detail: nil, group_members: [])
        else
          socket
        end

      {:noreply, assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("view_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Groups.admin_get_group(id) do
        {:ok, group} ->
          members = Groups.admin_list_members(id)

          {:noreply, assign(socket, group_detail: group, group_members: members)}

        {:error, _} ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("admin_add_member", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      group = socket.assigns.group_detail

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, put_flash(socket, :error, "User not found")}

        user ->
          case Groups.admin_add_member(group.id, user.id, "member") do
            {:ok, _} ->
              {:noreply,
               assign(socket,
                 group_members: Groups.admin_list_members(group.id)
               )}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, action_error("add member", reason))}
          end
      end
    end)
  end

  def handle_event("admin_remove_member", %{"user-id" => user_id}, socket) do
    require_admin(socket, fn ->
      group = socket.assigns.group_detail
      Groups.admin_remove_member(group.id, user_id)

      {:noreply, assign(socket, group_members: Groups.admin_list_members(group.id))}
    end)
  end

  def render_tab(assigns) do
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
end
