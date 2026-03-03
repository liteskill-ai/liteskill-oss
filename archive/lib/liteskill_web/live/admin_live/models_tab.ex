defmodule LiteskillWeb.AdminLive.ModelsTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2, build_model_attrs: 2]
  import LiteskillWeb.FormatHelpers
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders

  def assigns do
    [
      llm_models: [],
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      or_search: "",
      or_results: [],
      or_loading: false,
      embed_results_all: [],
      embed_search: "",
      embed_results: []
    ]
  end

  def load_data(socket) do
    assign(socket,
      llm_providers: LlmProviders.list_all_providers(),
      llm_models: LlmModels.list_all_models(),
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      page_title: "Model Management"
    )
  end

  def handle_event("new_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       assign(socket,
         editing_llm_model: :new,
         llm_model_form: to_form(%{}, as: :llm_model)
       )}
    end)
  end

  def handle_event("cancel_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, editing_llm_model: nil)}
    end)
  end

  def handle_event("create_llm_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_model_attrs(params, socket.assigns.current_user.id),
           {:ok, _model} <- LlmModels.create_model(attrs) do
        {:noreply,
         socket
         |> assign(
           llm_models: LlmModels.list_all_models(),
           editing_llm_model: nil
         )
         |> put_flash(:info, "Model created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("create model", reason))}
      end
    end)
  end

  def handle_event("edit_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.get_model_for_admin(id) do
        {:ok, model} ->
          config_json =
            if model.model_config && model.model_config != %{},
              do: Jason.encode!(model.model_config),
              else: ""

          form_data = %{
            "name" => model.name,
            "provider_id" => model.provider_id,
            "model_id" => model.model_id,
            "model_type" => model.model_type,
            "model_config_json" => config_json,
            "instance_wide" => if(model.instance_wide, do: "true", else: "false"),
            "status" => model.status,
            "input_cost_per_million" => format_decimal(model.input_cost_per_million),
            "output_cost_per_million" => format_decimal(model.output_cost_per_million)
          }

          {:noreply,
           assign(socket,
             editing_llm_model: id,
             llm_model_form: to_form(form_data, as: :llm_model)
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("load model", reason))}
      end
    end)
  end

  def handle_event("update_llm_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      id = params["id"]

      with {:ok, attrs} <- build_model_attrs(params, socket.assigns.current_user.id),
           {:ok, _model} <- LlmModels.update_model(id, socket.assigns.current_user.id, attrs) do
        {:noreply,
         socket
         |> assign(
           llm_models: LlmModels.list_all_models(),
           editing_llm_model: nil
         )
         |> put_flash(:info, "Model updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("update model", reason))}
      end
    end)
  end

  def handle_event("delete_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.delete_model(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             llm_models: LlmModels.list_all_models(),
             editing_llm_model: nil
           )
           |> put_flash(:info, "Model deleted")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("delete model", reason))}
      end
    end)
  end

  def render_tab(assigns) do
    model_types = Liteskill.LlmModels.LlmModel.valid_model_types()
    assigns = assign(assigns, :model_types, model_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Models</h2>
          <div :if={!@editing_llm_model} class="flex gap-2">
            <.link navigate={~p"/admin/setup"} class="btn btn-outline btn-sm">
              Run Setup Wizard
            </.link>
            <button
              :if={@llm_providers != []}
              phx-click="new_llm_model"
              class="btn btn-primary btn-sm"
            >
              Add Model
            </button>
          </div>
        </div>

        <div :if={@editing_llm_model} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @editing_llm_model == :new, do: "Add New Model", else: "Edit Model"}
          </h3>
          <.form
            for={@llm_model_form}
            phx-submit={
              if @editing_llm_model == :new, do: "create_llm_model", else: "update_llm_model"
            }
            class="space-y-3"
          >
            <input
              :if={@editing_llm_model != :new}
              type="hidden"
              name="llm_model[id]"
              value={@editing_llm_model}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Display Name</span></label>
                <input
                  type="text"
                  name="llm_model[name]"
                  value={@llm_model_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="Claude Sonnet (US East)"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider</span></label>
                <select
                  name="llm_model[provider_id]"
                  class="select select-bordered select-sm w-full"
                  required
                >
                  <%= for p <- @llm_providers do %>
                    <option
                      value={p.id}
                      selected={@llm_model_form[:provider_id].value == p.id}
                    >
                      {p.name} ({p.provider_type})
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Model ID</span></label>
                <input
                  type="text"
                  name="llm_model[model_id]"
                  value={@llm_model_form[:model_id].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="us.anthropic.claude-3-5-sonnet-20241022-v2:0"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Model Type</span></label>
                <select
                  name="llm_model[model_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for mt <- @model_types do %>
                    <option
                      value={mt}
                      selected={@llm_model_form[:model_type].value == mt}
                    >
                      {mt}
                    </option>
                  <% end %>
                </select>
              </div>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Input Cost / 1M tokens ($)</span>
                </label>
                <input
                  type="number"
                  name="llm_model[input_cost_per_million]"
                  value={
                    @llm_model_form[:input_cost_per_million] &&
                      @llm_model_form[:input_cost_per_million].value
                  }
                  class="input input-bordered input-sm w-full"
                  step="0.01"
                  min="0"
                  placeholder="3.00"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Output Cost / 1M tokens ($)</span>
                </label>
                <input
                  type="number"
                  name="llm_model[output_cost_per_million]"
                  value={
                    @llm_model_form[:output_cost_per_million] &&
                      @llm_model_form[:output_cost_per_million].value
                  }
                  class="input input-bordered input-sm w-full"
                  step="0.01"
                  min="0"
                  placeholder="15.00"
                />
              </div>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Model Config (JSON)</span>
              </label>
              <textarea
                name="llm_model[model_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"max_tokens": 4096}'
              >{@llm_model_form[:model_config_json] && @llm_model_form[:model_config_json].value}</textarea>
            </div>
            <div class="flex items-center gap-4">
              <label class="label cursor-pointer gap-2">
                <input
                  type="checkbox"
                  name="llm_model[instance_wide]"
                  value="true"
                  checked={@llm_model_form[:instance_wide].value == "true"}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">Instance-wide (all users)</span>
              </label>
              <select
                name="llm_model[status]"
                class="select select-bordered select-sm"
              >
                <option value="active" selected={@llm_model_form[:status].value != "inactive"}>
                  Active
                </option>
                <option value="inactive" selected={@llm_model_form[:status].value == "inactive"}>
                  Inactive
                </option>
              </select>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" phx-click="cancel_llm_model" class="btn btn-ghost btn-sm">
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
                <th>Provider</th>
                <th>Model ID</th>
                <th>Type</th>
                <th>Pricing (per 1M)</th>
                <th>Scope</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for model <- @llm_models do %>
                <tr>
                  <td class="font-medium">{model.name}</td>
                  <td>
                    <span class="badge badge-sm badge-neutral">
                      {model.provider && model.provider.name}
                    </span>
                  </td>
                  <td class="font-mono text-sm max-w-xs truncate">{model.model_id}</td>
                  <td><span class="badge badge-sm badge-ghost">{model.model_type}</span></td>
                  <td class="text-sm">
                    <%= if model.input_cost_per_million || model.output_cost_per_million do %>
                      <span class="text-base-content/60">In:</span>
                      ${format_decimal(model.input_cost_per_million)}
                      <span class="text-base-content/40 mx-1">/</span>
                      <span class="text-base-content/60">Out:</span>
                      ${format_decimal(model.output_cost_per_million)}
                    <% else %>
                      <span class="text-base-content/40">—</span>
                    <% end %>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      model.instance_wide && "badge-primary",
                      !model.instance_wide && "badge-outline"
                    ]}>
                      {if model.instance_wide, do: "Instance", else: "Scoped"}
                    </span>
                  </td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      model.status == "active" && "badge-success",
                      model.status == "inactive" && "badge-warning"
                    ]}>
                      {model.status}
                    </span>
                  </td>
                  <td class="flex gap-1">
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="llm_model"
                      phx-value-entity-id={model.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Share
                    </button>
                    <button
                      phx-click="edit_llm_model"
                      phx-value-id={model.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_llm_model"
                      phx-value-id={model.id}
                      data-confirm="Delete this model configuration?"
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@llm_models == []} class="text-base-content/60 text-center py-4">
            {if @llm_providers == [],
              do: "Add a provider first, then configure models.",
              else: "No models configured. Add one to get started."}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
