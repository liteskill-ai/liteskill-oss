defmodule LiteskillWeb.SharingComponents do
  @moduledoc """
  Reusable sharing modal component for all entity types.
  """

  use Phoenix.Component

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :show, :boolean, required: true
  attr :entity_type, :string, required: true
  attr :entity_id, :string, default: nil
  attr :acls, :list, default: []
  attr :user_search_results, :list, default: []
  attr :user_search_query, :string, default: ""
  attr :groups, :list, default: []
  attr :current_user_id, :string, required: true
  attr :error, :string, default: nil

  def sharing_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id="sharing-modal"
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_sharing"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_sharing" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-md mx-4 max-h-[90vh] overflow-y-auto z-10">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">
            Share {humanize_entity_type(@entity_type)}
          </h3>
          <button phx-click="close_sharing" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>

        <div class="p-4 space-y-4">
          <%!-- User search --%>
          <form phx-change="search_users" phx-submit="search_users" class="relative">
            <label class="label pb-1">
              <span class="label-text text-sm font-medium">Add people</span>
            </label>
            <input
              type="text"
              name="user_search"
              value={@user_search_query}
              placeholder="Search by name or email..."
              phx-debounce="300"
              class="input input-bordered input-sm w-full"
              autocomplete="off"
            />

            <%!-- Search results dropdown --%>
            <div
              :if={@user_search_results != []}
              class="absolute z-10 mt-1 w-full bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-48 overflow-y-auto"
            >
              <button
                :for={user <- @user_search_results}
                type="button"
                phx-click="grant_access"
                phx-value-user-id={user.id}
                phx-value-role={if @entity_type == "wiki_space", do: "editor", else: "manager"}
                class="w-full flex items-center gap-3 px-3 py-2 hover:bg-base-200 transition-colors text-left"
              >
                <div class="bg-primary/10 text-primary rounded-full w-8 h-8 flex items-center justify-center shrink-0">
                  <span class="text-xs font-bold uppercase">
                    {String.first(user.name || user.email)}
                  </span>
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium truncate">{user.name || "Unnamed"}</p>
                  <p class="text-xs text-base-content/50 truncate">{user.email}</p>
                </div>
              </button>
            </div>
          </form>

          <%!-- Group access --%>
          <div :if={@groups != []}>
            <label class="label pb-1">
              <span class="label-text text-sm font-medium">Add group</span>
            </label>
            <div class="flex flex-wrap gap-2">
              <button
                :for={group <- @groups}
                type="button"
                phx-click="grant_group_access"
                phx-value-group-id={group.id}
                phx-value-role={if @entity_type == "wiki_space", do: "editor", else: "manager"}
                class="btn btn-outline btn-xs gap-1"
              >
                <.icon name="hero-user-group-micro" class="size-3" />
                {group.name}
              </button>
            </div>
          </div>

          <%!-- Error message --%>
          <div :if={@error} class="text-error text-sm">{@error}</div>

          <%!-- Current access list --%>
          <div>
            <label class="label pb-1">
              <span class="label-text text-sm font-medium">People with access</span>
            </label>
            <div class="space-y-2">
              <div
                :for={acl <- @acls}
                class="flex items-center justify-between gap-2 px-3 py-2 bg-base-200/50 rounded-lg"
              >
                <div class="flex items-center gap-2 min-w-0">
                  <div class="bg-primary/10 text-primary rounded-full w-7 h-7 flex items-center justify-center shrink-0">
                    <span class="text-xs font-bold uppercase">
                      {acl_initial(acl)}
                    </span>
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium truncate">{acl_label(acl)}</p>
                  </div>
                </div>

                <div class="flex items-center gap-1">
                  <%= if acl.role == "owner" do %>
                    <span class="badge badge-sm badge-primary">Owner</span>
                  <% else %>
                    <select
                      phx-change="change_role"
                      phx-value-acl-id={acl.id}
                      name="role"
                      class="select select-xs select-bordered"
                    >
                      <option value="viewer" selected={acl.role == "viewer"}>Viewer</option>
                      <option
                        :if={@entity_type == "wiki_space"}
                        value="editor"
                        selected={acl.role == "editor"}
                      >
                        Editor
                      </option>
                      <option value="manager" selected={acl.role == "manager"}>Manager</option>
                    </select>
                    <button
                      phx-click={if acl.user_id, do: "revoke_access", else: "revoke_group_access"}
                      phx-value-user-id={acl.user_id}
                      phx-value-group-id={acl.group_id}
                      class="btn btn-ghost btn-xs btn-square text-error/70 hover:text-error"
                      title="Remove access"
                    >
                      <.icon name="hero-x-mark-micro" class="size-4" />
                    </button>
                  <% end %>
                </div>
              </div>

              <p :if={@acls == []} class="text-sm text-base-content/50 text-center py-2">
                Only you have access
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp humanize_entity_type("conversation"), do: "Conversation"
  defp humanize_entity_type("report"), do: "Report"
  defp humanize_entity_type("source"), do: "Data Source"
  defp humanize_entity_type("mcp_server"), do: "Tool Server"
  defp humanize_entity_type("wiki_space"), do: "Wiki Space"
  defp humanize_entity_type(other), do: other

  defp acl_initial(acl) do
    cond do
      acl.user && acl.user.name -> String.first(acl.user.name)
      acl.user && acl.user.email -> String.first(acl.user.email)
      acl.group && acl.group.name -> String.first(acl.group.name)
      true -> "?"
    end
  end

  defp acl_label(acl) do
    cond do
      acl.user -> acl.user.name || acl.user.email
      acl.group -> acl.group.name
      true -> "Unknown"
    end
  end
end
