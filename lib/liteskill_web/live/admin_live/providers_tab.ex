defmodule LiteskillWeb.AdminLive.ProvidersTab do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]
  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2, build_provider_attrs: 2]

  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider

  def assigns do
    [
      llm_providers: [],
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider)
    ]
  end

  def load_data(socket) do
    assign(socket,
      llm_providers: LlmProviders.list_all_providers(),
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider),
      page_title: "Provider Management"
    )
  end

  def handle_event("new_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       assign(socket,
         editing_llm_provider: :new,
         llm_provider_form: to_form(%{}, as: :llm_provider)
       )}
    end)
  end

  def handle_event("cancel_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, editing_llm_provider: nil)}
    end)
  end

  def handle_event("create_llm_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_provider_attrs(params, socket.assigns.current_user.id),
           {:ok, _provider} <- LlmProviders.create_provider(attrs) do
        {:noreply,
         socket
         |> assign(
           llm_providers: LlmProviders.list_all_providers(),
           editing_llm_provider: nil
         )
         |> put_flash(:info, "Provider created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("create provider", reason))}
      end
    end)
  end

  def handle_event("edit_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.get_provider_for_admin(id) do
        {:ok, provider} ->
          config_json =
            if provider.provider_config && provider.provider_config != %{},
              do: Jason.encode!(provider.provider_config),
              else: ""

          form_data = %{
            "name" => provider.name,
            "provider_type" => provider.provider_type,
            "api_key" => "",
            "provider_config_json" => config_json,
            "instance_wide" => if(provider.instance_wide, do: "true", else: "false"),
            "status" => provider.status
          }

          {:noreply,
           assign(socket,
             editing_llm_provider: id,
             llm_provider_form: to_form(form_data, as: :llm_provider)
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("load provider", reason))}
      end
    end)
  end

  def handle_event("update_llm_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      id = params["id"]

      with {:ok, attrs} <- build_provider_attrs(params, socket.assigns.current_user.id),
           {:ok, _provider} <-
             LlmProviders.update_provider(id, socket.assigns.current_user.id, attrs) do
        {:noreply,
         socket
         |> assign(
           llm_providers: LlmProviders.list_all_providers(),
           editing_llm_provider: nil
         )
         |> put_flash(:info, "Provider updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("update provider", reason))}
      end
    end)
  end

  def handle_event("delete_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.delete_provider(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             llm_providers: LlmProviders.list_all_providers(),
             editing_llm_provider: nil
           )
           |> put_flash(:info, "Provider deleted")}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("delete provider", reason)
           )}
      end
    end)
  end

  def render_tab(assigns) do
    provider_types = LlmProvider.valid_provider_types()
    assigns = assign(assigns, :provider_types, provider_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Providers</h2>
          <div :if={!@editing_llm_provider} class="flex gap-2">
            <.link navigate={~p"/admin/setup"} class="btn btn-outline btn-sm">
              Run Setup Wizard
            </.link>
            <button phx-click="new_llm_provider" class="btn btn-primary btn-sm">
              Add Provider
            </button>
          </div>
        </div>

        <div :if={@editing_llm_provider} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @editing_llm_provider == :new, do: "Add New Provider", else: "Edit Provider"}
          </h3>
          <.form
            for={@llm_provider_form}
            phx-submit={
              if @editing_llm_provider == :new,
                do: "create_llm_provider",
                else: "update_llm_provider"
            }
            class="space-y-3"
          >
            <input
              :if={@editing_llm_provider != :new}
              type="hidden"
              name="llm_provider[id]"
              value={@editing_llm_provider}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name="llm_provider[name]"
                  value={@llm_provider_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="AWS Bedrock US-East"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider Type</span></label>
                <select
                  name="llm_provider[provider_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for pt <- @provider_types do %>
                    <option
                      value={pt}
                      selected={@llm_provider_form[:provider_type].value == pt}
                    >
                      {pt}
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">API Key</span></label>
                <input
                  type="password"
                  name="llm_provider[api_key]"
                  value={@llm_provider_form[:api_key].value}
                  class="input input-bordered input-sm w-full"
                  placeholder="Optional — encrypted at rest"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Status</span></label>
                <select
                  name="llm_provider[status]"
                  class="select select-bordered select-sm w-full"
                >
                  <option
                    value="active"
                    selected={@llm_provider_form[:status].value != "inactive"}
                  >
                    Active
                  </option>
                  <option
                    value="inactive"
                    selected={@llm_provider_form[:status].value == "inactive"}
                  >
                    Inactive
                  </option>
                </select>
              </div>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Provider Config (JSON)</span>
              </label>
              <textarea
                name="llm_provider[provider_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"region": "us-east-1"}'
              >{@llm_provider_form[:provider_config_json] && @llm_provider_form[:provider_config_json].value}</textarea>
            </div>
            <label class="label cursor-pointer gap-2 w-fit">
              <input
                type="checkbox"
                name="llm_provider[instance_wide]"
                value="true"
                checked={@llm_provider_form[:instance_wide].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Instance-wide (all users)</span>
            </label>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                phx-click="cancel_llm_provider"
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
                <th>Scope</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for provider <- @llm_providers do %>
                <tr>
                  <td class="font-medium">{provider.name}</td>
                  <td>
                    <span class="badge badge-sm badge-neutral">{provider.provider_type}</span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      provider.instance_wide && "badge-primary",
                      !provider.instance_wide && "badge-outline"
                    ]}>
                      {if provider.instance_wide, do: "Instance", else: "Scoped"}
                    </span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      provider.status == "active" && "badge-success",
                      provider.status == "inactive" && "badge-warning"
                    ]}>
                      {provider.status}
                    </span>
                  </td>
                  <td class="flex gap-1">
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="llm_provider"
                      phx-value-entity-id={provider.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Share
                    </button>
                    <button
                      phx-click="edit_llm_provider"
                      phx-value-id={provider.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_llm_provider"
                      phx-value-id={provider.id}
                      data-confirm="Delete this provider? Models using it must be reassigned first."
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@llm_providers == []} class="text-base-content/60 text-center py-4">
            No providers configured. Add one to get started.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
