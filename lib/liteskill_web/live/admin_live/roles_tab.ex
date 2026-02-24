defmodule LiteskillWeb.AdminLive.RolesTab do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]
  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]

  alias Liteskill.Accounts
  alias Liteskill.Groups

  def assigns do
    [
      rbac_roles: [],
      editing_role: nil,
      role_form: to_form(%{}, as: :role),
      role_users: [],
      role_groups: [],
      role_user_search: ""
    ]
  end

  def load_data(socket) do
    assign(socket,
      rbac_roles: Liteskill.Rbac.list_roles(),
      editing_role: nil,
      role_form: to_form(%{}, as: :role),
      role_users: [],
      role_groups: [],
      role_user_search: "",
      page_title: "Role Management"
    )
  end

  def handle_event("new_role", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       assign(socket,
         editing_role: :new,
         role_form: to_form(%{}, as: :role)
       )}
    end)
  end

  def handle_event("cancel_role", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, editing_role: nil)}
    end)
  end

  def handle_event("edit_role", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Liteskill.Rbac.get_role(id) do
        {:ok, role} ->
          form_data = %{
            "name" => role.name,
            "description" => role.description || "",
            "permissions" => role.permissions
          }

          {:noreply,
           assign(socket,
             editing_role: role,
             role_form: to_form(form_data, as: :role),
             role_users: Liteskill.Rbac.list_role_users(role.id),
             role_groups: Liteskill.Rbac.list_role_groups(role.id)
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("load role", reason))}
      end
    end)
  end

  def handle_event("create_role", %{"role" => params}, socket) do
    require_admin(socket, fn ->
      attrs = %{
        name: params["name"],
        description: params["description"],
        permissions: params["permissions"] || []
      }

      case Liteskill.Rbac.create_role(attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             rbac_roles: Liteskill.Rbac.list_roles(),
             editing_role: nil
           )
           |> put_flash(:info, "Role created")}

        {:error, changeset} ->
          msg = format_changeset(changeset)
          {:noreply, put_flash(socket, :error, msg)}
      end
    end)
  end

  def handle_event("update_role", %{"role" => params}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      attrs = %{
        name: params["name"],
        description: params["description"],
        permissions: params["permissions"] || []
      }

      case Liteskill.Rbac.update_role(role, attrs) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(
             rbac_roles: Liteskill.Rbac.list_roles(),
             editing_role: updated,
             role_form:
               to_form(
                 %{
                   "name" => updated.name,
                   "description" => updated.description || "",
                   "permissions" => updated.permissions
                 },
                 as: :role
               )
           )
           |> put_flash(:info, "Role updated")}

        {:error, changeset} ->
          msg = format_changeset(changeset)
          {:noreply, put_flash(socket, :error, msg)}
      end
    end)
  end

  def handle_event("delete_role", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Liteskill.Rbac.get_role(id) do
        {:ok, role} ->
          case Liteskill.Rbac.delete_role(role) do
            {:ok, _} ->
              {:noreply,
               socket
               |> assign(
                 rbac_roles: Liteskill.Rbac.list_roles(),
                 editing_role: nil
               )
               |> put_flash(:info, "Role deleted")}

            {:error, :cannot_delete_system_role} ->
              {:noreply, put_flash(socket, :error, "Cannot delete system roles")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, action_error("delete role", reason))}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("load role", reason))}
      end
    end)
  end

  def handle_event("assign_role_user", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, put_flash(socket, :error, "User not found")}

        user ->
          case Liteskill.Rbac.assign_role_to_user(user.id, role.id) do
            {:ok, _} ->
              {:noreply,
               assign(socket,
                 role_users: Liteskill.Rbac.list_role_users(role.id)
               )}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 action_error("assign role to user", reason)
               )}
          end
      end
    end)
  end

  def handle_event("remove_role_user", %{"user-id" => user_id}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      case Liteskill.Rbac.remove_role_from_user(user_id, role.id) do
        {:ok, _} ->
          {:noreply,
           assign(socket,
             role_users: Liteskill.Rbac.list_role_users(role.id)
           )}

        {:error, :cannot_remove_root_admin} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cannot remove Instance Admin from root admin"
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("remove user from role", reason)
           )}
      end
    end)
  end

  def handle_event("assign_role_group", %{"group_name" => name}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      case Groups.admin_get_group_by_name(name) do
        nil ->
          {:noreply, put_flash(socket, :error, "Group not found")}

        group ->
          case Liteskill.Rbac.assign_role_to_group(group.id, role.id) do
            {:ok, _} ->
              {:noreply,
               assign(socket,
                 role_groups: Liteskill.Rbac.list_role_groups(role.id)
               )}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 action_error("assign role to group", reason)
               )}
          end
      end
    end)
  end

  def handle_event("remove_role_group", %{"group-id" => group_id}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      case Liteskill.Rbac.remove_role_from_group(group_id, role.id) do
        {:ok, _} ->
          {:noreply,
           assign(socket,
             role_groups: Liteskill.Rbac.list_role_groups(role.id)
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("remove group from role", reason)
           )}
      end
    end)
  end

  def render_tab(assigns) do
    grouped_permissions = Liteskill.Rbac.Permissions.grouped()
    assigns = assign(assigns, :grouped_permissions, grouped_permissions)

    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Role Management</h2>
        <button phx-click="new_role" class="btn btn-primary btn-sm">
          <.icon name="hero-plus-micro" class="size-4" /> New Role
        </button>
      </div>

      <%!-- Role list --%>
      <div class="overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th>Name</th>
              <th>Description</th>
              <th>Type</th>
              <th>Permissions</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for role <- @rbac_roles do %>
              <tr>
                <td class="font-medium">{role.name}</td>
                <td class="text-sm text-base-content/60">{role.description || "—"}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    role.system && "badge-primary",
                    !role.system && "badge-outline"
                  ]}>
                    {if role.system, do: "System", else: "Custom"}
                  </span>
                </td>
                <td>
                  <span class="badge badge-sm badge-ghost">
                    {if "*" in role.permissions,
                      do: "All",
                      else: "#{length(role.permissions)} permissions"}
                  </span>
                </td>
                <td class="flex gap-1">
                  <button
                    phx-click="edit_role"
                    phx-value-id={role.id}
                    class="btn btn-ghost btn-xs"
                  >
                    {if role.name == "Instance Admin", do: "View", else: "Edit"}
                  </button>
                  <button
                    :if={!role.system}
                    phx-click="delete_role"
                    phx-value-id={role.id}
                    data-confirm="Delete this role? Users and groups will lose its permissions."
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

      <%!-- Role detail panel --%>
      <%= if @editing_role do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h3 class="card-title">
                {if @editing_role == :new, do: "New Role", else: @editing_role.name}
              </h3>
              <button type="button" phx-click="cancel_role" class="btn btn-ghost btn-sm">
                Close
              </button>
            </div>

            <%!-- Instance Admin: read-only view --%>
            <%= if @editing_role != :new && @editing_role.name == "Instance Admin" do %>
              <div class="alert alert-info">
                <.icon name="hero-shield-check-micro" class="size-5" />
                <span>
                  The Instance Admin role always has full access to everything.
                  Its permissions cannot be changed.
                </span>
              </div>
              <div class="text-sm text-base-content/60">
                {if @editing_role.description,
                  do: @editing_role.description,
                  else: "Full system access"}
              </div>
            <% else %>
              <%!-- Editable form for all other roles --%>
              <.form
                for={@role_form}
                phx-submit={if @editing_role == :new, do: "create_role", else: "update_role"}
                class="space-y-4"
              >
                <input
                  :if={@editing_role != :new}
                  type="hidden"
                  name="role[id]"
                  value={@editing_role.id}
                />

                <div class="form-control">
                  <label class="label"><span class="label-text">Name</span></label>
                  <input
                    type="text"
                    name="role[name]"
                    value={Phoenix.HTML.Form.input_value(@role_form, :name)}
                    class="input input-bordered"
                    required
                    disabled={@editing_role != :new && @editing_role.system}
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Description</span></label>
                  <input
                    type="text"
                    name="role[description]"
                    value={Phoenix.HTML.Form.input_value(@role_form, :description)}
                    class="input input-bordered"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Permissions</span></label>
                  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                    <%= for {category, perms} <- @grouped_permissions do %>
                      <div class="border border-base-300 rounded-lg p-3">
                        <h4 class="font-semibold text-sm mb-2 capitalize">{category}</h4>
                        <%= for perm <- perms do %>
                          <label class="flex items-center gap-2 py-0.5 cursor-pointer">
                            <input
                              type="checkbox"
                              name="role[permissions][]"
                              value={perm}
                              checked={
                                perm in (Phoenix.HTML.Form.input_value(@role_form, :permissions) ||
                                           [])
                              }
                              class="checkbox checkbox-sm"
                            />
                            <span class="text-xs">{perm}</span>
                          </label>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="flex gap-2">
                  <button type="submit" class="btn btn-primary btn-sm">
                    {if @editing_role == :new, do: "Create", else: "Update"}
                  </button>
                  <button type="button" phx-click="cancel_role" class="btn btn-ghost btn-sm">
                    Cancel
                  </button>
                </div>
              </.form>
            <% end %>

            <%!-- User/Group assignments (only for existing roles) --%>
            <%= if @editing_role != :new do %>
              <div class="divider">Assigned Users</div>
              <div class="space-y-2">
                <form phx-submit="assign_role_user" class="flex gap-2">
                  <input
                    type="text"
                    name="email"
                    placeholder="User email"
                    class="input input-bordered input-sm flex-1"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">Add</button>
                </form>
                <div class="flex flex-wrap gap-2">
                  <%= for user <- @role_users do %>
                    <span class="badge badge-lg gap-2">
                      {user.email}
                      <button
                        phx-click="remove_role_user"
                        phx-value-user-id={user.id}
                        class="btn btn-ghost btn-xs"
                      >
                        x
                      </button>
                    </span>
                  <% end %>
                </div>
              </div>

              <div class="divider">Assigned Groups</div>
              <div class="space-y-2">
                <form phx-submit="assign_role_group" class="flex gap-2">
                  <input
                    type="text"
                    name="group_name"
                    placeholder="Group name"
                    class="input input-bordered input-sm flex-1"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">Add</button>
                </form>
                <div class="flex flex-wrap gap-2">
                  <%= for group <- @role_groups do %>
                    <span class="badge badge-lg gap-2">
                      {group.name}
                      <button
                        phx-click="remove_role_group"
                        phx-value-group-id={group.id}
                        class="btn btn-ghost btn-xs"
                      >
                        x
                      </button>
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
