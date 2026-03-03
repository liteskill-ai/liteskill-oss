defmodule LiteskillWeb.ProfileLive do
  @moduledoc """
  Profile components and event handlers, rendered within ChatLive's main area.
  Handles user-facing settings: account info, password change, and personal
  LLM provider/model management.
  """

  use LiteskillWeb, :live_view

  import LiteskillWeb.FormatHelpers

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.Chat
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider
  alias LiteskillWeb.AdminLive
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.SettingsLive

  @profile_actions [:info, :password, :user_providers, :user_models]

  def profile_action?(action), do: action in @profile_actions

  def profile_assigns do
    [
      password_form: to_form(%{"current" => "", "new" => "", "confirm" => ""}, as: :password),
      password_error: nil,
      password_success: false,
      user_llm_providers: [],
      user_editing_provider: nil,
      user_provider_form: nil,
      user_llm_models: [],
      user_editing_model: nil,
      user_model_form: nil
    ]
  end

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(profile_assigns())
     |> assign(
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id),
       single_user_mode: Liteskill.SingleUser.enabled?()
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns.current_user.force_password_change &&
         socket.assigns.live_action != :password do
      {:noreply, push_navigate(socket, to: ~p"/profile/password")}
    else
      {:noreply, apply_action(socket, socket.assigns.live_action)}
    end
  end

  defp apply_action(socket, action) when action in @profile_actions do
    apply_profile_action(socket, action, socket.assigns.current_user)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative">
      <Layouts.sidebar
        sidebar_open={@sidebar_open}
        live_action={@live_action}
        conversations={@conversations}
        active_conversation_id={nil}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
        single_user_mode={@single_user_mode}
      />

      <main class="flex-1 flex flex-col min-w-0">
        <.profile
          live_action={@live_action}
          current_user={@current_user}
          sidebar_open={@sidebar_open}
          password_form={@password_form}
          password_error={@password_error}
          password_success={@password_success}
          user_llm_providers={@user_llm_providers}
          user_editing_provider={@user_editing_provider}
          user_provider_form={@user_provider_form}
          user_llm_models={@user_llm_models}
          user_editing_model={@user_editing_model}
          user_model_form={@user_model_form}
        />
      </main>
    </div>
    """
  end

  def apply_profile_action(socket, action, _user) do
    load_tab_data(socket, action)
  end

  defp load_tab_data(socket, :password) do
    assign(socket,
      page_title: "Change Password",
      password_error: nil,
      password_success: false
    )
  end

  defp load_tab_data(socket, :user_providers) do
    user_id = socket.assigns.current_user.id

    assign(socket,
      page_title: "My Providers",
      user_llm_providers: LlmProviders.list_owned_providers(user_id),
      user_editing_provider: nil
    )
  end

  defp load_tab_data(socket, :user_models) do
    user_id = socket.assigns.current_user.id

    assign(socket,
      page_title: "My Models",
      user_llm_providers: LlmProviders.list_owned_providers(user_id),
      user_llm_models: LlmModels.list_owned_models(user_id),
      user_editing_model: nil
    )
  end

  defp load_tab_data(socket, _action) do
    assign(socket, page_title: "Profile")
  end

  # --- Public component ---

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, required: true
  attr :password_form, :any, required: true
  attr :password_error, :string
  attr :password_success, :boolean
  attr :user_llm_providers, :list
  attr :user_editing_provider, :any
  attr :user_provider_form, :any
  attr :user_llm_models, :list
  attr :user_editing_model, :any
  attr :user_model_form, :any
  attr :settings_mode, :boolean, default: false
  attr :settings_action, :atom, default: nil

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
        <h1 class="text-lg font-semibold">{if @settings_mode, do: "Settings", else: "Profile"}</h1>
      </div>
    </header>

    <div class="border-b border-base-300 px-4 flex-shrink-0">
      <%= if @settings_mode do %>
        <SettingsLive.settings_tab_bar active={@settings_action} />
      <% else %>
        <div class="flex gap-1 overflow-x-auto" role="tablist">
          <.tab_link label="Info" to={~p"/profile"} active={@live_action == :info} />
          <.tab_link label="Password" to={~p"/profile/password"} active={@live_action == :password} />
          <.tab_link
            label="Providers"
            to={~p"/profile/providers"}
            active={@live_action == :user_providers}
          />
          <.tab_link label="Models" to={~p"/profile/models"} active={@live_action == :user_models} />
        </div>
      <% end %>
    </div>

    <div class="flex-1 overflow-y-auto p-6">
      <div class="mx-auto max-w-3xl">
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
                @current_user.role == "admin" && "badge-primary",
                @current_user.role != "admin" && "badge-neutral"
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
    <div :if={@current_user.force_password_change} class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle-mini" class="size-5" />
      <span>You must change your password before continuing.</span>
    </div>
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

  # --- Providers Tab ---

  defp render_tab(%{live_action: :user_providers} = assigns) do
    provider_types = LlmProvider.valid_provider_types()
    assigns = assign(assigns, :provider_types, provider_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">My Providers</h2>
          <button
            :if={!@user_editing_provider}
            phx-click="user_new_provider"
            class="btn btn-primary btn-sm"
          >
            Add Provider
          </button>
        </div>

        <div :if={@user_editing_provider} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @user_editing_provider == :new, do: "Add New Provider", else: "Edit Provider"}
          </h3>
          <.form
            for={@user_provider_form}
            phx-submit={
              if @user_editing_provider == :new,
                do: "user_create_provider",
                else: "user_update_provider"
            }
            class="space-y-3"
          >
            <input
              :if={@user_editing_provider != :new}
              type="hidden"
              name="user_provider[id]"
              value={@user_editing_provider}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name="user_provider[name]"
                  value={@user_provider_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="My OpenAI"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider Type</span></label>
                <select
                  name="user_provider[provider_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for pt <- @provider_types do %>
                    <option
                      value={pt}
                      selected={@user_provider_form[:provider_type].value == pt}
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
                  name="user_provider[api_key]"
                  value={@user_provider_form[:api_key].value}
                  class="input input-bordered input-sm w-full"
                  placeholder="Optional — encrypted at rest"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Status</span></label>
                <select
                  name="user_provider[status]"
                  class="select select-bordered select-sm w-full"
                >
                  <option
                    value="active"
                    selected={@user_provider_form[:status].value != "inactive"}
                  >
                    Active
                  </option>
                  <option
                    value="inactive"
                    selected={@user_provider_form[:status].value == "inactive"}
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
                name="user_provider[provider_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"region": "us-east-1"}'
              >{@user_provider_form[:provider_config_json] && @user_provider_form[:provider_config_json].value}</textarea>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                phx-click="user_cancel_provider"
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
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for provider <- @user_llm_providers do %>
                <tr>
                  <td class="font-medium">{provider.name}</td>
                  <td>
                    <span class="badge badge-sm badge-neutral">{provider.provider_type}</span>
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
                      phx-click="user_edit_provider"
                      phx-value-id={provider.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="user_delete_provider"
                      phx-value-id={provider.id}
                      data-confirm="Delete this provider? Models using it will lose their provider."
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@user_llm_providers == []} class="text-base-content/60 text-center py-4">
            No providers yet. Add one to get started.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # --- Models Tab ---

  defp render_tab(%{live_action: :user_models} = assigns) do
    model_types = LlmModels.LlmModel.valid_model_types()
    assigns = assign(assigns, :model_types, model_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">My Models</h2>
          <button
            :if={!@user_editing_model && @user_llm_providers != []}
            phx-click="user_new_model"
            class="btn btn-primary btn-sm"
          >
            Add Model
          </button>
        </div>

        <p
          :if={@user_llm_providers == [] && !@user_editing_model}
          class="text-base-content/60 text-center py-4"
        >
          You need at least one provider before adding models.
          <.link navigate={~p"/profile/providers"} class="link link-primary">
            Add a provider
          </.link>
        </p>

        <div :if={@user_editing_model} class="mb-6 p-4 border border-base-300 rounded-lg">
          <h3 class="font-semibold mb-3">
            {if @user_editing_model == :new, do: "Add New Model", else: "Edit Model"}
          </h3>
          <.form
            for={@user_model_form}
            phx-submit={
              if @user_editing_model == :new, do: "user_create_model", else: "user_update_model"
            }
            class="space-y-3"
          >
            <input
              :if={@user_editing_model != :new}
              type="hidden"
              name="user_model[id]"
              value={@user_editing_model}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Display Name</span></label>
                <input
                  type="text"
                  name="user_model[name]"
                  value={@user_model_form[:name].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="My GPT-4o"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider</span></label>
                <select
                  name="user_model[provider_id]"
                  class="select select-bordered select-sm w-full"
                  required
                >
                  <%= for p <- @user_llm_providers do %>
                    <option
                      value={p.id}
                      selected={@user_model_form[:provider_id].value == p.id}
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
                  name="user_model[model_id]"
                  value={@user_model_form[:model_id].value}
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="gpt-4o"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Model Type</span></label>
                <select
                  name="user_model[model_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for mt <- @model_types do %>
                    <option
                      value={mt}
                      selected={@user_model_form[:model_type].value == mt}
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
                  name="user_model[input_cost_per_million]"
                  value={
                    @user_model_form[:input_cost_per_million] &&
                      @user_model_form[:input_cost_per_million].value
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
                  name="user_model[output_cost_per_million]"
                  value={
                    @user_model_form[:output_cost_per_million] &&
                      @user_model_form[:output_cost_per_million].value
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
                name="user_model[model_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"max_tokens": 4096}'
              >{@user_model_form[:model_config_json] && @user_model_form[:model_config_json].value}</textarea>
            </div>
            <div class="flex items-center gap-4">
              <select
                name="user_model[status]"
                class="select select-bordered select-sm"
              >
                <option value="active" selected={@user_model_form[:status].value != "inactive"}>
                  Active
                </option>
                <option value="inactive" selected={@user_model_form[:status].value == "inactive"}>
                  Inactive
                </option>
              </select>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" phx-click="user_cancel_model" class="btn btn-ghost btn-sm">
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div :if={@user_llm_providers != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Provider</th>
                <th>Model ID</th>
                <th>Type</th>
                <th>Pricing (per 1M)</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for model <- @user_llm_models do %>
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
                      model.status == "active" && "badge-success",
                      model.status == "inactive" && "badge-warning"
                    ]}>
                      {model.status}
                    </span>
                  </td>
                  <td class="flex gap-1">
                    <button
                      phx-click="user_edit_model"
                      phx-value-id={model.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="user_delete_model"
                      phx-value-id={model.id}
                      data-confirm="Delete this model?"
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <p :if={@user_llm_models == []} class="text-base-content/60 text-center py-4">
            No models yet. Add one to get started.
          </p>
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

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

  @impl true
  def handle_event("change_password", %{"password" => params}, socket) do
    current = params["current"]
    new_pass = params["new"]
    confirm = params["confirm"]

    cond do
      new_pass != confirm ->
        {:noreply,
         assign(socket,
           password_error: "Passwords do not match",
           password_success: false
         )}

      String.length(new_pass) < 12 ->
        {:noreply,
         assign(socket,
           password_error: "New password must be at least 12 characters",
           password_success: false
         )}

      true ->
        case Accounts.change_password(socket.assigns.current_user, current, new_pass) do
          {:ok, user} ->
            {:noreply,
             assign(socket,
               current_user: user,
               password_error: nil,
               password_success: true,
               password_form: to_form(%{"current" => "", "new" => "", "confirm" => ""}, as: :password)
             )}

          {:error, :invalid_current_password} ->
            {:noreply,
             assign(socket,
               password_error: "Current password is incorrect",
               password_success: false
             )}

          {:error, _changeset} ->
            {:noreply,
             assign(socket,
               password_error: "Failed to change password",
               password_success: false
             )}
        end
    end
  end

  @impl true
  def handle_event("set_accent_color", %{"color" => color}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_preferences(user, %{"accent_color" => color}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(current_user: updated_user)
         |> Phoenix.LiveView.push_event("set-accent", %{color: color})}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # --- User Provider Event Handlers ---

  @impl true
  def handle_event("user_new_provider", _params, socket) do
    {:noreply,
     assign(socket,
       user_editing_provider: :new,
       user_provider_form: to_form(%{}, as: :user_provider)
     )}
  end

  @impl true
  def handle_event("user_cancel_provider", _params, socket) do
    {:noreply, assign(socket, user_editing_provider: nil)}
  end

  @impl true
  def handle_event("user_create_provider", %{"user_provider" => params}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, attrs} <- AdminLive.build_provider_attrs(params, user_id),
         attrs = Map.put(attrs, :instance_wide, false),
         {:ok, _provider} <- LlmProviders.create_provider(attrs) do
      {:noreply,
       socket
       |> assign(
         user_llm_providers: LlmProviders.list_owned_providers(user_id),
         user_editing_provider: nil
       )
       |> put_flash(:info, "Provider created")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("create provider", reason))}
    end
  end

  @impl true
  def handle_event("user_edit_provider", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case LlmProviders.get_provider_for_owner(id, user_id) do
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
          "status" => provider.status
        }

        {:noreply,
         assign(socket,
           user_editing_provider: id,
           user_provider_form: to_form(form_data, as: :user_provider)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load provider", reason))}
    end
  end

  @impl true
  def handle_event("user_update_provider", %{"user_provider" => params}, socket) do
    user_id = socket.assigns.current_user.id
    id = params["id"]

    with {:ok, attrs} <- AdminLive.build_provider_attrs(params, user_id),
         attrs = Map.put(attrs, :instance_wide, false),
         {:ok, _provider} <- LlmProviders.update_provider(id, user_id, attrs) do
      {:noreply,
       socket
       |> assign(
         user_llm_providers: LlmProviders.list_owned_providers(user_id),
         user_editing_provider: nil
       )
       |> put_flash(:info, "Provider updated")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("update provider", reason))}
    end
  end

  @impl true
  def handle_event("user_delete_provider", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case LlmProviders.delete_provider(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           user_llm_providers: LlmProviders.list_owned_providers(user_id),
           user_editing_provider: nil
         )
         |> put_flash(:info, "Provider deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete provider", reason))}
    end
  end

  # --- User Model Event Handlers ---

  @impl true
  def handle_event("user_new_model", _params, socket) do
    {:noreply,
     assign(socket,
       user_editing_model: :new,
       user_model_form: to_form(%{}, as: :user_model)
     )}
  end

  @impl true
  def handle_event("user_cancel_model", _params, socket) do
    {:noreply, assign(socket, user_editing_model: nil)}
  end

  @impl true
  def handle_event("user_create_model", %{"user_model" => params}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, attrs} <- AdminLive.build_model_attrs(params, user_id),
         attrs = Map.put(attrs, :instance_wide, false),
         {:ok, _model} <- LlmModels.create_model(attrs) do
      {:noreply,
       socket
       |> assign(
         user_llm_models: LlmModels.list_owned_models(user_id),
         user_editing_model: nil
       )
       |> put_flash(:info, "Model created")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("create model", reason))}
    end
  end

  @impl true
  def handle_event("user_edit_model", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case LlmModels.get_model_for_owner(id, user_id) do
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
          "input_cost_per_million" => model.input_cost_per_million && Decimal.to_string(model.input_cost_per_million),
          "output_cost_per_million" => model.output_cost_per_million && Decimal.to_string(model.output_cost_per_million),
          "status" => model.status
        }

        {:noreply,
         assign(socket,
           user_editing_model: id,
           user_model_form: to_form(form_data, as: :user_model)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load model", reason))}
    end
  end

  @impl true
  def handle_event("user_update_model", %{"user_model" => params}, socket) do
    user_id = socket.assigns.current_user.id
    id = params["id"]

    with {:ok, attrs} <- AdminLive.build_model_attrs(params, user_id),
         attrs = Map.put(attrs, :instance_wide, false),
         {:ok, _model} <- LlmModels.update_model(id, user_id, attrs) do
      {:noreply,
       socket
       |> assign(
         user_llm_models: LlmModels.list_owned_models(user_id),
         user_editing_model: nil
       )
       |> put_flash(:info, "Model updated")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("update model", reason))}
    end
  end

  @impl true
  def handle_event("user_delete_model", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case LlmModels.delete_model(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           user_llm_models: LlmModels.list_owned_models(user_id),
           user_editing_model: nil
         )
         |> put_flash(:info, "Model deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete model", reason))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
