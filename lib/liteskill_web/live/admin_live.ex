defmodule LiteskillWeb.AdminLive do
  @moduledoc """
  Admin panel components and event handlers, rendered within ChatLive's main area.
  Handles server management, user/group management, LLM providers/models, and usage analytics.
  """

  use LiteskillWeb, :html

  import LiteskillWeb.ErrorHelpers
  import LiteskillWeb.FormatHelpers

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.DataSources
  alias Liteskill.Groups
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Settings
  alias Liteskill.Usage
  alias LiteskillWeb.SourcesComponents

  @admin_actions [
    :admin_usage,
    :admin_servers,
    :admin_users,
    :admin_groups,
    :admin_providers,
    :admin_models,
    :admin_roles,
    :admin_rag,
    :admin_setup
  ]

  def admin_action?(action), do: action in @admin_actions

  def admin_assigns do
    [
      profile_users: [],
      profile_groups: [],
      group_detail: nil,
      group_members: [],
      temp_password_user_id: nil,
      llm_models: [],
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      llm_providers: [],
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider),
      server_settings: nil,
      invitations: [],
      new_invitation_url: nil,
      admin_usage_data: %{},
      admin_usage_period: "30d",
      setup_step: :password,
      setup_form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
      setup_error: nil,
      setup_selected_permissions: MapSet.new(),
      setup_data_sources: [],
      setup_selected_sources: MapSet.new(),
      setup_sources_to_configure: [],
      setup_current_config_index: 0,
      setup_config_form: to_form(%{}, as: :config),
      rbac_roles: [],
      editing_role: nil,
      role_form: to_form(%{}, as: :role),
      role_users: [],
      role_groups: [],
      role_user_search: "",
      rag_embedding_models: [],
      rag_current_model: nil,
      rag_stats: %{},
      rag_confirm_change: false,
      rag_confirm_input: "",
      rag_selected_model_id: nil,
      rag_reembed_in_progress: false
    ]
  end

  def apply_admin_action(socket, action, user) do
    if !Liteskill.Rbac.has_any_admin_permission?(user.id) do
      Phoenix.LiveView.push_navigate(socket, to: ~p"/profile")
    else
      load_tab_data(socket, action)
    end
  end

  defp load_tab_data(socket, :admin_usage) do
    period = socket.assigns[:admin_usage_period] || "30d"
    usage_data = load_usage_data(period)

    Phoenix.Component.assign(socket,
      page_title: "Usage Analytics",
      admin_usage_data: usage_data,
      admin_usage_period: period
    )
  end

  defp load_tab_data(socket, :admin_users) do
    Phoenix.Component.assign(socket,
      profile_users: Accounts.list_users(),
      invitations: Accounts.list_invitations(),
      new_invitation_url: nil,
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
    Phoenix.Component.assign(socket,
      page_title: "Server Management",
      server_settings: Settings.get()
    )
  end

  defp load_tab_data(socket, :admin_setup) do
    user_id = socket.assigns.current_user.id
    available = DataSources.available_source_types()

    existing_types =
      available
      |> Enum.map(& &1.source_type)
      |> Enum.filter(&DataSources.get_source_by_type(user_id, &1))
      |> MapSet.new()

    default_perms =
      case Liteskill.Rbac.get_role_by_name!("Default") do
        %{permissions: perms} -> MapSet.new(perms)
      end

    Phoenix.Component.assign(socket,
      page_title: "Setup Wizard",
      setup_step: :password,
      setup_form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
      setup_error: nil,
      setup_selected_permissions: default_perms,
      setup_data_sources: available,
      setup_selected_sources: existing_types,
      setup_sources_to_configure: [],
      setup_current_config_index: 0,
      setup_config_form: to_form(%{}, as: :config)
    )
  end

  defp load_tab_data(socket, :admin_providers) do
    user_id = socket.assigns.current_user.id

    Phoenix.Component.assign(socket,
      llm_providers: LlmProviders.list_providers(user_id),
      editing_llm_provider: nil,
      llm_provider_form: to_form(%{}, as: :llm_provider),
      page_title: "Provider Management"
    )
  end

  defp load_tab_data(socket, :admin_models) do
    user_id = socket.assigns.current_user.id

    Phoenix.Component.assign(socket,
      llm_providers: LlmProviders.list_providers(user_id),
      llm_models: LlmModels.list_models(user_id),
      editing_llm_model: nil,
      llm_model_form: to_form(%{}, as: :llm_model),
      page_title: "Model Management"
    )
  end

  defp load_tab_data(socket, :admin_roles) do
    Phoenix.Component.assign(socket,
      rbac_roles: Liteskill.Rbac.list_roles(),
      editing_role: nil,
      role_form: to_form(%{}, as: :role),
      role_users: [],
      role_groups: [],
      role_user_search: "",
      page_title: "Role Management"
    )
  end

  defp load_tab_data(socket, :admin_rag) do
    user_id = socket.assigns.current_user.id
    settings = Settings.get()
    embedding_models = LlmModels.list_active_models(user_id, model_type: "embedding")
    stats = Liteskill.Rag.Pipeline.public_summary()
    reembed_in_progress = reembed_jobs_in_progress?()

    Phoenix.Component.assign(socket,
      page_title: "RAG Settings",
      server_settings: settings,
      rag_embedding_models: embedding_models,
      rag_current_model: settings.embedding_model,
      rag_stats: stats,
      rag_confirm_change: false,
      rag_confirm_input: "",
      rag_selected_model_id: nil,
      rag_reembed_in_progress: reembed_in_progress
    )
  end

  defp reembed_jobs_in_progress? do
    import Ecto.Query

    Liteskill.Repo.exists?(
      from(j in "oban_jobs",
        where:
          j.queue == "rag_ingest" and
            j.worker == "Liteskill.Rag.ReembedWorker" and
            j.state in ["available", "executing", "scheduled"]
      )
    )
  end

  defp load_usage_data(period) do
    time_opts = period_to_opts(period)

    instance = Usage.instance_totals(time_opts)
    by_user = Usage.usage_summary(Keyword.merge(time_opts, group_by: :user_id))
    by_model = Usage.usage_summary(Keyword.merge(time_opts, group_by: :model_id))
    daily = Usage.daily_totals(time_opts)

    users = Accounts.list_users()
    user_map = Map.new(users, fn u -> {u.id, u} end)

    groups = Groups.list_all_groups()
    group_ids = Enum.map(groups, & &1.id)
    group_usage_map = Usage.usage_by_groups(group_ids, time_opts)

    group_usage =
      groups
      |> Enum.map(fn group ->
        %{
          group: group,
          usage: Map.get(group_usage_map, group.id, %{total_tokens: 0, call_count: 0})
        }
      end)
      |> Enum.sort_by(fn %{usage: u} -> u.total_tokens end, :desc)

    embedding_totals = Usage.embedding_totals(time_opts)
    embedding_by_model = Usage.embedding_by_model(time_opts)
    embedding_by_user = Usage.embedding_by_user(time_opts)

    %{
      instance: instance,
      by_user: by_user,
      by_model: by_model,
      daily: daily,
      user_map: user_map,
      group_usage: group_usage,
      embedding_totals: embedding_totals,
      embedding_by_model: embedding_by_model,
      embedding_by_user: embedding_by_user
    }
  end

  defp period_to_opts("7d") do
    [from: DateTime.add(DateTime.utc_now(), -7, :day)]
  end

  defp period_to_opts("30d") do
    [from: DateTime.add(DateTime.utc_now(), -30, :day)]
  end

  defp period_to_opts("90d") do
    [from: DateTime.add(DateTime.utc_now(), -90, :day)]
  end

  defp period_to_opts("all"), do: []

  # --- Public component ---

  attr :live_action, :atom, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, required: true
  attr :profile_users, :list, default: []
  attr :profile_groups, :list, default: []
  attr :group_detail, :any
  attr :group_members, :list, default: []
  attr :temp_password_user_id, :string, default: nil
  attr :llm_models, :list, default: []
  attr :editing_llm_model, :any, default: nil
  attr :llm_model_form, :any
  attr :llm_providers, :list, default: []
  attr :editing_llm_provider, :any, default: nil
  attr :llm_provider_form, :any
  attr :server_settings, :any, default: nil
  attr :invitations, :list, default: []
  attr :new_invitation_url, :string, default: nil
  attr :admin_usage_data, :map, default: %{}
  attr :admin_usage_period, :string, default: "30d"
  attr :setup_step, :atom, default: :password
  attr :setup_form, :any
  attr :setup_error, :string, default: nil
  attr :setup_selected_permissions, :any, default: nil
  attr :setup_data_sources, :list, default: []
  attr :setup_selected_sources, :any, default: nil
  attr :setup_sources_to_configure, :list, default: []
  attr :setup_current_config_index, :integer, default: 0
  attr :setup_config_form, :any
  attr :rbac_roles, :list, default: []
  attr :editing_role, :any, default: nil
  attr :role_form, :any
  attr :role_users, :list, default: []
  attr :role_groups, :list, default: []
  attr :role_user_search, :string, default: ""
  attr :rag_embedding_models, :list, default: []
  attr :rag_current_model, :any, default: nil
  attr :rag_stats, :map, default: %{}
  attr :rag_confirm_change, :boolean, default: false
  attr :rag_confirm_input, :string, default: ""
  attr :rag_selected_model_id, :string, default: nil
  attr :rag_reembed_in_progress, :boolean, default: false

  def admin_panel(assigns) do
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
        <h1 class="text-lg font-semibold">Admin</h1>
      </div>
    </header>

    <div class="border-b border-base-300 px-4 flex-shrink-0">
      <div class="flex gap-1 overflow-x-auto" role="tablist">
        <.tab_link
          label="Usage"
          to={~p"/admin/usage"}
          active={@live_action == :admin_usage}
        />
        <.tab_link
          label="Server"
          to={~p"/admin/servers"}
          active={@live_action == :admin_servers}
        />
        <.tab_link
          label="Users"
          to={~p"/admin/users"}
          active={@live_action == :admin_users}
        />
        <.tab_link
          label="Groups"
          to={~p"/admin/groups"}
          active={@live_action == :admin_groups}
        />
        <.tab_link
          label="Providers"
          to={~p"/admin/providers"}
          active={@live_action == :admin_providers}
        />
        <.tab_link
          label="Models"
          to={~p"/admin/models"}
          active={@live_action == :admin_models}
        />
        <.tab_link
          label="Roles"
          to={~p"/admin/roles"}
          active={@live_action == :admin_roles}
        />
        <.tab_link
          label="RAG"
          to={~p"/admin/rag"}
          active={@live_action == :admin_rag}
        />
      </div>
    </div>

    <div class="flex-1 overflow-y-auto p-6">
      <div class={[
        "mx-auto",
        if(
          @live_action in [
            :admin_providers,
            :admin_models,
            :admin_users,
            :admin_groups,
            :admin_usage,
            :admin_roles,
            :admin_rag
          ],
          do: "max-w-6xl",
          else: "max-w-3xl"
        )
      ]}>
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

  # --- Usage Tab ---

  defp render_tab(%{live_action: :admin_usage} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Usage Analytics</h2>
        <div class="flex gap-1">
          <button
            :for={
              {label, value} <- [
                {"7 days", "7d"},
                {"30 days", "30d"},
                {"90 days", "90d"},
                {"All time", "all"}
              ]
            }
            phx-click="admin_usage_period"
            phx-value-period={value}
            class={[
              "btn btn-sm",
              if(@admin_usage_period == value, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <.usage_instance_summary usage={@admin_usage_data[:instance]} />
      <.usage_daily_chart daily={@admin_usage_data[:daily] || []} />
      <.usage_by_model data={@admin_usage_data[:by_model] || []} />
      <.usage_by_user
        data={@admin_usage_data[:by_user] || []}
        user_map={@admin_usage_data[:user_map] || %{}}
      />
      <.usage_by_group data={@admin_usage_data[:group_usage] || []} />

      <.embedding_usage_summary totals={@admin_usage_data[:embedding_totals]} />
      <.embedding_usage_by_model data={@admin_usage_data[:embedding_by_model] || []} />
      <.embedding_usage_by_user
        data={@admin_usage_data[:embedding_by_user] || []}
        user_map={@admin_usage_data[:user_map] || %{}}
      />
    </div>
    """
  end

  # --- Setup Wizard Tab (admin) ---

  defp render_tab(%{live_action: :admin_setup} = assigns) do
    ~H"""
    <div class="flex justify-center">
      <div class="w-full max-w-2xl">
        <div class="mb-4">
          <.link navigate={~p"/admin/servers"} class="btn btn-ghost btn-sm gap-1">
            <.icon name="hero-arrow-left-micro" class="size-4" /> Back to Server
          </.link>
        </div>

        <div class="flex gap-2 mb-6">
          <.setup_step_indicator
            label="Password"
            step={:password}
            current={@setup_step}
            index={1}
          />
          <.setup_step_indicator
            label="Permissions"
            step={:default_permissions}
            current={@setup_step}
            index={2}
          />
          <.setup_step_indicator
            label="Data Sources"
            step={:data_sources}
            current={@setup_step}
            index={3}
          />
          <.setup_step_indicator
            label="Configure"
            step={:configure_source}
            current={@setup_step}
            index={4}
          />
        </div>

        <%= case @setup_step do %>
          <% :password -> %>
            <.setup_password_step form={@setup_form} error={@setup_error} />
          <% :default_permissions -> %>
            <.setup_default_permissions_step selected_permissions={@setup_selected_permissions} />
          <% :data_sources -> %>
            <.setup_data_sources_step
              data_sources={@setup_data_sources}
              selected_sources={@setup_selected_sources}
            />
          <% :configure_source -> %>
            <.setup_configure_step
              source={Enum.at(@setup_sources_to_configure, @setup_current_config_index)}
              config_form={@setup_config_form}
              current_index={@setup_current_config_index}
              total={length(@setup_sources_to_configure)}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # --- Server Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_servers} = assigns) do
    repo_config = Liteskill.Repo.config()
    oban_config = Application.get_env(:liteskill, Oban, [])
    oidc_config = Application.get_env(:ueberauth, Ueberauth.Strategy.OIDCC, [])

    assigns =
      assigns
      |> assign(:repo_config, repo_config)
      |> assign(:oban_config, oban_config)
      |> assign(:oidc_config, oidc_config)

    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="card-title">Setup Wizard</h2>
              <p class="text-sm text-base-content/60 mt-1">
                Re-run the initial setup wizard to update admin password and data source connections.
              </p>
            </div>
            <.link navigate={~p"/admin/setup"} class="btn btn-primary btn-sm gap-1">
              <.icon name="hero-arrow-path-micro" class="size-4" /> Run Setup
            </.link>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Registration</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Public Registration</p>
              <p class="text-sm text-base-content/60">
                {if @server_settings && @server_settings.registration_open,
                  do: "Anyone can create an account",
                  else: "Only invited users can create accounts"}
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@server_settings && @server_settings.registration_open}
              phx-click="toggle_registration"
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Cost Guardrails</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Default MCP Run Cost Limit</p>
              <p class="text-sm text-base-content/60">
                Maximum cost (USD) for agent runs started via MCP tools.
                Users cannot exceed this limit.
              </p>
            </div>
            <form phx-change="update_mcp_cost_limit" class="flex items-center gap-1">
              <span class="text-sm text-base-content/60">$</span>
              <input
                type="number"
                name="cost_limit"
                step="0.10"
                min="0.10"
                value={
                  @server_settings && @server_settings.default_mcp_run_cost_limit &&
                    Decimal.to_string(@server_settings.default_mcp_run_cost_limit)
                }
                class="input input-bordered input-sm w-24"
                phx-debounce="500"
              />
            </form>
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

  # --- Provider Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_providers} = assigns) do
    provider_types = LlmProvider.valid_provider_types()
    assigns = assign(assigns, :provider_types, provider_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Providers</h2>
          <button
            :if={!@editing_llm_provider}
            phx-click="new_llm_provider"
            class="btn btn-primary btn-sm"
          >
            Add Provider
          </button>
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

  # --- Model Management Tab (admin) ---

  defp render_tab(%{live_action: :admin_models} = assigns) do
    model_types = Liteskill.LlmModels.LlmModel.valid_model_types()
    assigns = assign(assigns, :model_types, model_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title">LLM Models</h2>
          <button
            :if={!@editing_llm_model && @llm_providers != []}
            phx-click="new_llm_model"
            class="btn btn-primary btn-sm"
          >
            Add Model
          </button>
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

  defp render_tab(%{live_action: :admin_roles} = assigns) do
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

  # --- RAG Tab ---

  defp render_tab(%{live_action: :admin_rag} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Embedding Model</h2>
          <%= if @rag_current_model do %>
            <div class="flex items-center gap-2 mt-2">
              <span class="badge badge-success">Active</span>
              <span class="font-medium">{@rag_current_model.name}</span>
              <span class="text-sm text-base-content/60">({@rag_current_model.model_id})</span>
            </div>
          <% else %>
            <div class="alert alert-warning mt-2">
              <.icon name="hero-exclamation-triangle-micro" class="size-5" />
              <span>No embedding model selected. RAG ingest is disabled.</span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Pipeline Stats</h2>
          <div class="stats stats-horizontal shadow mt-2">
            <div class="stat">
              <div class="stat-title">Sources</div>
              <div class="stat-value text-lg">{@rag_stats[:source_count] || 0}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Documents</div>
              <div class="stat-value text-lg">{@rag_stats[:document_count] || 0}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Chunks</div>
              <div class="stat-value text-lg">{@rag_stats[:chunk_count] || 0}</div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@rag_reembed_in_progress} class="alert alert-info">
        <.icon name="hero-arrow-path-micro" class="size-5 animate-spin" />
        <span>Re-embedding is currently in progress. This may take a while.</span>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Change Embedding Model</h2>
          <p class="text-sm text-base-content/60 mt-1">
            Changing the model will clear <strong>all existing embeddings</strong>
            and re-generate them using the new model. This is a destructive and
            potentially time-consuming operation.
          </p>

          <%= if @rag_embedding_models == [] do %>
            <div class="alert alert-warning mt-4">
              <.icon name="hero-information-circle-micro" class="size-5" />
              <span>
                No embedding models configured. Add a model with type "embedding"
                in the <.link navigate={~p"/admin/models"} class="link link-primary">Models</.link>
                tab first.
              </span>
            </div>
          <% else %>
            <form phx-submit="rag_select_model" class="flex items-end gap-3 mt-4">
              <div class="form-control flex-1">
                <label class="label"><span class="label-text">Select Model</span></label>
                <select name="model_id" class="select select-bordered w-full">
                  <option value="">-- None (disable RAG) --</option>
                  <option
                    :for={model <- @rag_embedding_models}
                    value={model.id}
                    selected={@rag_current_model && model.id == @rag_current_model.id}
                  >
                    {model.name} ({model.model_id})
                  </option>
                </select>
              </div>
              <button
                type="submit"
                class="btn btn-warning"
                disabled={@rag_reembed_in_progress}
              >
                Change Model
              </button>
            </form>
          <% end %>
        </div>
      </div>

      <%= if @rag_confirm_change do %>
        <div
          class="fixed inset-0 z-50 flex items-center justify-center"
          phx-window-keydown="rag_cancel_change"
          phx-key="Escape"
        >
          <div class="fixed inset-0 bg-black/50" phx-click="rag_cancel_change" />
          <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-lg mx-4 z-10">
            <div class="p-6">
              <h3 class="text-lg font-bold text-error flex items-center gap-2">
                <.icon name="hero-exclamation-triangle-micro" class="size-6" /> Dangerous Operation
              </h3>
              <div class="mt-4 space-y-3">
                <p class="text-sm text-base-content/70">
                  This will <strong>permanently clear</strong>
                  all <span class="font-bold text-error">{@rag_stats[:chunk_count] || 0}</span>
                  chunk embeddings across
                  <span class="font-bold">{@rag_stats[:document_count] || 0}</span>
                  documents.
                </p>
                <p class="text-sm text-base-content/70">
                  All RAG search will be unavailable until re-embedding completes.
                  This may take a significant amount of time and will incur API costs.
                </p>
                <p class="text-sm font-medium mt-4">
                  Type the following to confirm:
                </p>
                <code class="block bg-base-200 px-3 py-2 rounded text-sm select-all">
                  I know what this means and I am very sure
                </code>
              </div>
              <form phx-submit="rag_confirm_model_change" class="mt-4">
                <input
                  type="text"
                  name="confirmation"
                  value={@rag_confirm_input}
                  phx-keyup="rag_confirm_input_change"
                  class="input input-bordered w-full"
                  autocomplete="off"
                  placeholder="Type confirmation text..."
                />
                <div class="flex justify-end gap-2 mt-4">
                  <button type="button" phx-click="rag_cancel_change" class="btn btn-ghost">
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class={[
                      "btn btn-error",
                      @rag_confirm_input != "I know what this means and I am very sure" &&
                        "btn-disabled"
                    ]}
                    disabled={@rag_confirm_input != "I know what this means and I am very sure"}
                  >
                    Confirm Change
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Setup Wizard Sub-Components ---

  defp setup_step_indicator(assigns) do
    status =
      cond do
        assigns.step == assigns.current -> :active
        step_index(assigns.step) < step_index(assigns.current) -> :done
        true -> :pending
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <div class="flex items-center gap-2 flex-1">
      <div class={[
        "size-6 rounded-full flex items-center justify-center text-xs font-bold",
        case @status do
          :done -> "bg-success text-success-content"
          :active -> "bg-primary text-primary-content"
          :pending -> "bg-base-300 text-base-content/50"
        end
      ]}>
        <%= if @status == :done do %>
          <.icon name="hero-check-micro" class="size-4" />
        <% else %>
          {@index}
        <% end %>
      </div>
      <span class={[
        "text-sm font-medium",
        if(@status == :pending, do: "text-base-content/50", else: "text-base-content")
      ]}>
        {@label}
      </span>
      <div :if={@index < 4} class="flex-1 h-px bg-base-300" />
    </div>
    """
  end

  defp step_index(:password), do: 1
  defp step_index(:default_permissions), do: 2
  defp step_index(:data_sources), do: 3
  defp step_index(:configure_source), do: 4

  defp setup_password_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Admin Password</h2>
        <p class="text-base-content/70">
          Set or update the admin account password. Skip if no change is needed.
        </p>

        <.form for={@form} phx-submit="setup_password" class="mt-4 space-y-4">
          <div class="form-control">
            <label class="label"><span class="label-text">New Password</span></label>
            <input
              type="password"
              name="setup[password]"
              value={Phoenix.HTML.Form.input_value(@form, :password)}
              placeholder="Minimum 12 characters"
              class="input input-bordered w-full"
              minlength="12"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Confirm Password</span></label>
            <input
              type="password"
              name="setup[password_confirmation]"
              value={Phoenix.HTML.Form.input_value(@form, :password_confirmation)}
              placeholder="Repeat password"
              class="input input-bordered w-full"
              minlength="12"
            />
          </div>

          <p :if={@error} class="text-error text-sm">{@error}</p>

          <div class="flex gap-3">
            <button type="button" phx-click="setup_skip_password" class="btn btn-ghost flex-1">
              Skip
            </button>
            <button type="submit" class="btn btn-primary flex-1">
              Set Password & Continue
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp setup_default_permissions_step(assigns) do
    grouped = Liteskill.Rbac.Permissions.grouped()
    assigns = assign(assigns, :grouped_permissions, grouped)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Default User Permissions</h2>
        <p class="text-base-content/70">
          Choose the baseline permissions that all users receive by default.
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
          <%= for {category, perms} <- @grouped_permissions do %>
            <div class="border border-base-300 rounded-lg p-3">
              <h4 class="font-semibold text-sm mb-2 capitalize">{category}</h4>
              <%= for perm <- perms do %>
                <label class="flex items-center gap-2 py-0.5 cursor-pointer">
                  <input
                    type="checkbox"
                    phx-click="setup_toggle_permission"
                    phx-value-permission={perm}
                    checked={MapSet.member?(@selected_permissions, perm)}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-xs">{perm}</span>
                </label>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_skip_permissions" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button type="button" phx-click="setup_save_permissions" class="btn btn-primary flex-1">
            Save & Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_data_sources_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Data Sources</h2>
        <p class="text-base-content/70">
          Select the data sources to integrate with. Already-connected sources are pre-selected.
        </p>

        <div class="grid grid-cols-2 sm:grid-cols-3 gap-4 mt-6">
          <%= for source <- @data_sources do %>
            <% coming_soon = source.source_type in ~w(sharepoint confluence jira github gitlab) %>
            <button
              type="button"
              phx-click={unless(coming_soon, do: "setup_toggle_source")}
              phx-value-source-type={source.source_type}
              disabled={coming_soon}
              class={[
                "flex flex-col items-center justify-center gap-3 p-6 rounded-xl border-2 transition-all duration-200",
                cond do
                  coming_soon ->
                    "border-base-300 opacity-50 cursor-not-allowed"

                  MapSet.member?(@selected_sources, source.source_type) ->
                    "bg-success/15 border-success shadow-md"

                  true ->
                    "bg-base-100 border-base-300 hover:border-base-content/30 cursor-pointer hover:scale-105"
                end
              ]}
            >
              <div class={[
                "size-12 flex items-center justify-center",
                if(MapSet.member?(@selected_sources, source.source_type),
                  do: "text-success",
                  else: "text-base-content/70"
                )
              ]}>
                <SourcesComponents.source_type_icon source_type={source.source_type} />
              </div>
              <span class={[
                "text-sm font-medium",
                if(MapSet.member?(@selected_sources, source.source_type),
                  do: "text-success",
                  else: "text-base-content"
                )
              ]}>
                {source.name}
              </span>
              <span :if={coming_soon} class="badge badge-xs badge-ghost">Coming Soon</span>
            </button>
          <% end %>
        </div>

        <div class="flex gap-3 mt-8">
          <button phx-click="setup_skip_sources" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button phx-click="setup_save_sources" class="btn btn-primary flex-1">
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_configure_step(assigns) do
    config_fields = DataSources.config_fields_for(assigns.source.source_type)
    assigns = assign(assigns, :config_fields, config_fields)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-xl">Configure {@source.name}</h2>
          <span class="text-sm text-base-content/50">
            {@current_index + 1} of {@total}
          </span>
        </div>
        <p class="text-base-content/70">
          Enter connection details for {@source.name}. Skip to keep existing config.
        </p>

        <div class="flex justify-center my-4">
          <div class="size-16">
            <SourcesComponents.source_type_icon source_type={@source.source_type} />
          </div>
        </div>

        <.form for={@config_form} phx-submit="setup_save_config" class="space-y-4">
          <div :for={field <- @config_fields} class="form-control">
            <label class="label"><span class="label-text">{field.label}</span></label>
            <%= if field.type == :textarea do %>
              <textarea
                name={"config[#{field.key}]"}
                placeholder={field.placeholder}
                class="textarea textarea-bordered w-full"
                rows="4"
              >{Phoenix.HTML.Form.input_value(@config_form, field.key)}</textarea>
            <% else %>
              <input
                type={if field.type == :password, do: "password", else: "text"}
                name={"config[#{field.key}]"}
                value={Phoenix.HTML.Form.input_value(@config_form, field.key)}
                placeholder={field.placeholder}
                class="input input-bordered w-full"
              />
            <% end %>
          </div>

          <div class="flex gap-3 mt-6">
            <button type="button" phx-click="setup_skip_config" class="btn btn-ghost flex-1">
              Skip
            </button>
            <button type="submit" class="btn btn-primary flex-1">
              Save & Continue
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # --- Usage Sub-Components ---

  defp usage_instance_summary(assigns) do
    usage = assigns[:usage] || %{}
    assigns = assign(assigns, :usage, usage)

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card label="Total Cost" value={format_cost(@usage[:total_cost])} />
      <.stat_card label="Input Cost" value={format_cost(@usage[:input_cost])} />
      <.stat_card label="Output Cost" value={format_cost(@usage[:output_cost])} />
      <.stat_card label="API Calls" value={format_number(@usage[:call_count] || 0)} />
      <.stat_card label="Total Tokens" value={format_number(@usage[:total_tokens] || 0)} />
      <.stat_card label="Input Tokens" value={format_number(@usage[:input_tokens] || 0)} />
      <.stat_card label="Output Tokens" value={format_number(@usage[:output_tokens] || 0)} />
      <.stat_card label="Reasoning Tokens" value={format_number(@usage[:reasoning_tokens] || 0)} />
      <.stat_card label="Cached Tokens" value={format_number(@usage[:cached_tokens] || 0)} />
      <.stat_card
        label="Cache Hit Rate"
        value={format_percentage(@usage[:cached_tokens] || 0, @usage[:input_tokens] || 0)}
      />
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-4">
        <div class="text-sm text-base-content/60">{@label}</div>
        <div class="text-2xl font-bold">{@value}</div>
      </div>
    </div>
    """
  end

  defp usage_daily_chart(assigns) do
    ~H"""
    <div :if={@daily != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Daily Usage</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Date</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Volume</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @daily}>
                <td class="font-mono text-sm">{format_date(day.date)}</td>
                <td class="text-right">{format_number(day.total_tokens)}</td>
                <td class="text-right">{format_cost(day.input_cost)}</td>
                <td class="text-right">{format_cost(day.output_cost)}</td>
                <td class="text-right">{format_cost(day.total_cost)}</td>
                <td class="text-right">{day.call_count}</td>
                <td>
                  <div class="w-32 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-primary h-2 rounded-full"
                      style={"width: #{bar_width(day.total_tokens, @daily)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_model(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Model</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Model</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-mono text-sm max-w-xs truncate">{row.model_id}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-secondary h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_user(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by User</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- Enum.sort_by(@data, & &1.total_tokens, :desc)}>
                <td>
                  <span :if={@user_map[row.user_id]} class="text-sm">
                    {@user_map[row.user_id].email}
                  </span>
                  <span :if={!@user_map[row.user_id]} class="text-sm text-base-content/50">
                    Unknown
                  </span>
                </td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-accent h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_group(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Group</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Group</th>
                <th class="text-right">Members</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{group: group, usage: usage} <- @data}>
                <td class="font-medium">{group.name}</td>
                <td class="text-right">{length(group.memberships)}</td>
                <td class="text-right">{format_number(usage.total_tokens)}</td>
                <td class="text-right">{format_cost(usage.input_cost)}</td>
                <td class="text-right">{format_cost(usage.output_cost)}</td>
                <td class="text-right">{format_cost(usage.total_cost)}</td>
                <td class="text-right">{usage.call_count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Embedding Usage Components ---

  defp embedding_usage_summary(%{totals: nil} = assigns) do
    ~H"""
    """
  end

  defp embedding_usage_summary(assigns) do
    error_rate =
      if assigns.totals.request_count > 0 do
        Float.round(assigns.totals.error_count / assigns.totals.request_count * 100, 1)
      else
        0.0
      end

    avg_ms = trunc(Decimal.to_float(assigns.totals.avg_latency_ms))
    assigns = assign(assigns, error_rate: error_rate, avg_ms: avg_ms)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding & Rerank Usage</h3>
        <div class="grid grid-cols-2 md:grid-cols-6 gap-4">
          <.stat_card label="Requests" value={format_number(@totals.request_count)} />
          <.stat_card label="Total Tokens" value={format_number(@totals.total_tokens)} />
          <.stat_card label="Inputs Processed" value={format_number(@totals.total_inputs)} />
          <.stat_card label="Est. Cost" value={format_cost(@totals.estimated_cost)} />
          <.stat_card label="Avg Latency" value={"#{@avg_ms}ms"} />
          <.stat_card label="Error Rate" value={"#{@error_rate}%"} />
        </div>
      </div>
    </div>
    """
  end

  defp embedding_usage_by_model(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding Usage by Model</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Model</th>
                <th class="text-right">Requests</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Inputs</th>
                <th class="text-right">Est. Cost</th>
                <th class="text-right">Errors</th>
                <th class="text-right">Avg Latency</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-medium font-mono text-xs">{row.model_id}</td>
                <td class="text-right">{format_number(row.request_count)}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.total_inputs)}</td>
                <td class="text-right">{format_cost(row.estimated_cost)}</td>
                <td class="text-right">{row.error_count}</td>
                <td class="text-right">{trunc(Decimal.to_float(row.avg_latency_ms))}ms</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp embedding_usage_by_user(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding Usage by User</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th class="text-right">Requests</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Inputs</th>
                <th class="text-right">Est. Cost</th>
                <th class="text-right">Errors</th>
                <th class="text-right">Avg Latency</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-medium">
                  {if user = @user_map[row.user_id], do: user.email, else: "Unknown"}
                </td>
                <td class="text-right">{format_number(row.request_count)}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.total_inputs)}</td>
                <td class="text-right">{format_cost(row.estimated_cost)}</td>
                <td class="text-right">{row.error_count}</td>
                <td class="text-right">{trunc(Decimal.to_float(row.avg_latency_ms))}ms</td>
              </tr>
            </tbody>
          </table>
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

  defp bar_width(_tokens, []), do: 0

  defp bar_width(tokens, daily) do
    max = daily |> Enum.map(& &1.total_tokens) |> Enum.max(fn -> 1 end)
    if max == 0, do: 0, else: Float.round(tokens / max * 100, 0)
  end

  defp token_share(_tokens, []), do: 0

  defp token_share(tokens, data) do
    total = data |> Enum.map(& &1.total_tokens) |> Enum.sum()
    if total == 0, do: 0, else: Float.round(tokens / total * 100, 0)
  end

  defp require_admin(socket, fun) do
    if Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id) do
      fun.()
    else
      {:noreply, socket}
    end
  end

  defp setup_advance_config(socket) do
    next_index = socket.assigns.setup_current_config_index + 1
    sources = socket.assigns.setup_sources_to_configure

    if next_index >= length(sources) do
      {:noreply, Phoenix.LiveView.push_navigate(socket, to: ~p"/admin/servers")}
    else
      user_id = socket.assigns.current_user.id
      next_source = Enum.at(sources, next_index)

      existing_metadata =
        case DataSources.get_source(next_source.db_id, user_id) do
          {:ok, s} -> s.metadata || %{}
          _ -> %{}
        end

      {:noreply,
       Phoenix.Component.assign(socket,
         setup_current_config_index: next_index,
         setup_config_form: to_form(existing_metadata, as: :config)
       )}
    end
  end

  # --- Setup Wizard Event Handlers ---

  def handle_event("setup_password", %{"setup" => params}, socket) do
    require_admin(socket, fn ->
      password = params["password"]
      confirmation = params["password_confirmation"]

      cond do
        password != confirmation ->
          {:noreply, Phoenix.Component.assign(socket, setup_error: "Passwords do not match")}

        String.length(password) < 12 ->
          {:noreply,
           Phoenix.Component.assign(socket,
             setup_error: "Password must be at least 12 characters"
           )}

        true ->
          case Accounts.setup_admin_password(socket.assigns.current_user, password) do
            {:ok, user} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 setup_step: :default_permissions,
                 current_user: user,
                 setup_error: nil
               )}

            {:error, reason} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 setup_error: action_error("set password", reason)
               )}
          end
      end
    end)
  end

  def handle_event("setup_skip_password", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket, setup_step: :default_permissions, setup_error: nil)}
    end)
  end

  def handle_event("setup_toggle_permission", %{"permission" => permission}, socket) do
    require_admin(socket, fn ->
      selected = socket.assigns.setup_selected_permissions

      selected =
        if MapSet.member?(selected, permission),
          do: MapSet.delete(selected, permission),
          else: MapSet.put(selected, permission)

      {:noreply, Phoenix.Component.assign(socket, setup_selected_permissions: selected)}
    end)
  end

  def handle_event("setup_save_permissions", _params, socket) do
    require_admin(socket, fn ->
      permissions = MapSet.to_list(socket.assigns.setup_selected_permissions)
      role = Liteskill.Rbac.get_role_by_name!("Default")

      case Liteskill.Rbac.update_role(role, %{permissions: permissions}) do
        {:ok, _} ->
          {:noreply, Phoenix.Component.assign(socket, setup_step: :data_sources)}

        {:error, reason} ->
          {:noreply,
           Phoenix.Component.assign(socket,
             setup_error: action_error("update permissions", reason)
           )}
      end
    end)
  end

  def handle_event("setup_skip_permissions", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, setup_step: :data_sources)}
    end)
  end

  def handle_event("setup_toggle_source", %{"source-type" => source_type}, socket) do
    require_admin(socket, fn ->
      selected = socket.assigns.setup_selected_sources

      selected =
        if MapSet.member?(selected, source_type),
          do: MapSet.delete(selected, source_type),
          else: MapSet.put(selected, source_type)

      {:noreply, Phoenix.Component.assign(socket, setup_selected_sources: selected)}
    end)
  end

  def handle_event("setup_save_sources", _params, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      selected = socket.assigns.setup_selected_sources
      data_sources = socket.assigns.setup_data_sources

      sources_to_configure =
        Enum.filter(data_sources, &MapSet.member?(selected, &1.source_type))

      if sources_to_configure == [] do
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: ~p"/admin/servers")}
      else
        {configured, _error} =
          Enum.reduce(sources_to_configure, {[], nil}, fn source, {acc, err} ->
            if err do
              {acc, err}
            else
              case DataSources.get_source_by_type(user_id, source.source_type) do
                %{id: id} ->
                  {[Map.put(source, :db_id, id) | acc], nil}

                nil ->
                  case DataSources.create_source(
                         %{
                           name: source.name,
                           source_type: source.source_type,
                           description: ""
                         },
                         user_id
                       ) do
                    {:ok, db_source} ->
                      {[Map.put(source, :db_id, db_source.id) | acc], nil}

                    {:error, reason} ->
                      {acc, action_error("create source #{source.name}", reason)}
                  end
              end
            end
          end)

        sources = Enum.reverse(configured)
        first = hd(sources)

        existing_metadata =
          case DataSources.get_source(first.db_id, user_id) do
            {:ok, s} -> s.metadata || %{}
            _ -> %{}
          end

        {:noreply,
         Phoenix.Component.assign(socket,
           setup_step: :configure_source,
           setup_sources_to_configure: sources,
           setup_current_config_index: 0,
           setup_config_form: to_form(existing_metadata, as: :config)
         )}
      end
    end)
  end

  def handle_event("setup_save_config", %{"config" => config_params}, socket) do
    require_admin(socket, fn ->
      current_source =
        Enum.at(
          socket.assigns.setup_sources_to_configure,
          socket.assigns.setup_current_config_index
        )

      user_id = socket.assigns.current_user.id

      metadata =
        config_params
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new()

      if metadata != %{} do
        DataSources.update_source(current_source.db_id, %{metadata: metadata}, user_id)
      end

      setup_advance_config(socket)
    end)
  end

  def handle_event("setup_skip_config", _params, socket) do
    require_admin(socket, fn ->
      setup_advance_config(socket)
    end)
  end

  def handle_event("setup_skip_sources", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.LiveView.push_navigate(socket, to: ~p"/admin/servers")}
    end)
  end

  # --- Event Handlers (called from ChatLive) ---

  def handle_event("admin_usage_period", %{"period" => period}, socket) do
    require_admin(socket, fn ->
      usage_data = load_usage_data(period)

      {:noreply,
       Phoenix.Component.assign(socket,
         admin_usage_data: usage_data,
         admin_usage_period: period
       )}
    end)
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "admin")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Accounts.update_user_role(id, "user")
      {:noreply, Phoenix.Component.assign(socket, profile_users: Accounts.list_users())}
    end)
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      Groups.create_group(name, user_id)
      {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("admin_delete_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      Groups.admin_delete_group(id)

      socket =
        if socket.assigns.group_detail && socket.assigns.group_detail.id == id do
          Phoenix.Component.assign(socket, group_detail: nil, group_members: [])
        else
          socket
        end

      {:noreply, Phoenix.Component.assign(socket, profile_groups: Groups.list_all_groups())}
    end)
  end

  def handle_event("view_group", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Groups.admin_get_group(id) do
        {:ok, group} ->
          members = Groups.admin_list_members(id)

          {:noreply,
           Phoenix.Component.assign(socket, group_detail: group, group_members: members)}

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
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "User not found")}

        user ->
          case Groups.admin_add_member(group.id, user.id, "member") do
            {:ok, _} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 group_members: Groups.admin_list_members(group.id)
               )}

            {:error, reason} ->
              {:noreply,
               Phoenix.LiveView.put_flash(socket, :error, action_error("add member", reason))}
          end
      end
    end)
  end

  def handle_event("admin_remove_member", %{"user-id" => user_id}, socket) do
    require_admin(socket, fn ->
      group = socket.assigns.group_detail
      Groups.admin_remove_member(group.id, user_id)

      {:noreply,
       Phoenix.Component.assign(socket, group_members: Groups.admin_list_members(group.id))}
    end)
  end

  def handle_event("show_temp_password_form", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, temp_password_user_id: id)}
  end

  def handle_event("cancel_temp_password", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, temp_password_user_id: nil)}
  end

  def handle_event("set_temp_password", %{"user_id" => id, "password" => password}, socket) do
    require_admin(socket, fn ->
      user = Accounts.get_user!(id)

      case Accounts.set_temporary_password(user, password) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             temp_password_user_id: nil,
             profile_users: Accounts.list_users()
           )
           |> Phoenix.LiveView.put_flash(
             :info,
             "Temporary password set. User must change it on next login."
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             action_error("set password", reason)
           )}
      end
    end)
  end

  # --- Registration & Invitation event handlers ---

  def handle_event("toggle_registration", _params, socket) do
    require_admin(socket, fn ->
      case Settings.toggle_registration() do
        {:ok, settings} ->
          {:noreply, Phoenix.Component.assign(socket, server_settings: settings)}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("toggle registration", reason))}
      end
    end)
  end

  def handle_event("update_mcp_cost_limit", %{"cost_limit" => val}, socket) do
    require_admin(socket, fn ->
      case parse_decimal(val) do
        nil ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Invalid cost limit")}

        cost_limit ->
          case Settings.update(%{default_mcp_run_cost_limit: cost_limit}) do
            {:ok, settings} ->
              {:noreply, Phoenix.Component.assign(socket, server_settings: settings)}

            {:error, reason} ->
              {:noreply,
               Phoenix.LiveView.put_flash(
                 socket,
                 :error,
                 action_error("update cost limit", reason)
               )}
          end
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
           |> Phoenix.Component.assign(
             invitations: Accounts.list_invitations(),
             new_invitation_url: url
           )
           |> Phoenix.LiveView.put_flash(:info, "Invitation created")}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("create invitation", reason))}
      end
    end)
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case Accounts.revoke_invitation(id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(invitations: Accounts.list_invitations())
           |> Phoenix.LiveView.put_flash(:info, "Invitation revoked")}

        {:error, :already_used} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, "Cannot revoke a used invitation")}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("revoke invitation", reason))}
      end
    end)
  end

  # --- LLM Provider event handlers ---

  def handle_event("new_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket,
         editing_llm_provider: :new,
         llm_provider_form: to_form(%{}, as: :llm_provider)
       )}
    end)
  end

  def handle_event("cancel_llm_provider", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, editing_llm_provider: nil)}
    end)
  end

  def handle_event("create_llm_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_provider_attrs(params, socket.assigns.current_user.id),
           {:ok, _provider} <- LlmProviders.create_provider(attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
           editing_llm_provider: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Provider created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("create provider", reason))}
      end
    end)
  end

  def handle_event("edit_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.get_provider(id, socket.assigns.current_user.id) do
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
           Phoenix.Component.assign(socket,
             editing_llm_provider: id,
             llm_provider_form: to_form(form_data, as: :llm_provider)
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("load provider", reason))}
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
         |> Phoenix.Component.assign(
           llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
           editing_llm_provider: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Provider updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("update provider", reason))}
      end
    end)
  end

  def handle_event("delete_llm_provider", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmProviders.delete_provider(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             llm_providers: LlmProviders.list_providers(socket.assigns.current_user.id),
             editing_llm_provider: nil
           )
           |> Phoenix.LiveView.put_flash(:info, "Provider deleted")}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             action_error("delete provider", reason)
           )}
      end
    end)
  end

  # --- LLM Model event handlers ---

  def handle_event("new_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket,
         editing_llm_model: :new,
         llm_model_form: to_form(%{}, as: :llm_model)
       )}
    end)
  end

  def handle_event("cancel_llm_model", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, editing_llm_model: nil)}
    end)
  end

  def handle_event("create_llm_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      with {:ok, attrs} <- build_model_attrs(params, socket.assigns.current_user.id),
           {:ok, _model} <- LlmModels.create_model(attrs) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(
           llm_models: LlmModels.list_models(socket.assigns.current_user.id),
           editing_llm_model: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Model created")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("create model", reason))}
      end
    end)
  end

  def handle_event("edit_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.get_model(id, socket.assigns.current_user.id) do
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
           Phoenix.Component.assign(socket,
             editing_llm_model: id,
             llm_model_form: to_form(form_data, as: :llm_model)
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("load model", reason))}
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
         |> Phoenix.Component.assign(
           llm_models: LlmModels.list_models(socket.assigns.current_user.id),
           editing_llm_model: nil
         )
         |> Phoenix.LiveView.put_flash(:info, "Model updated")}
      else
        {:error, msg} when is_binary(msg) ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("update model", reason))}
      end
    end)
  end

  def handle_event("delete_llm_model", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      case LlmModels.delete_model(id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(
             llm_models: LlmModels.list_models(socket.assigns.current_user.id),
             editing_llm_model: nil
           )
           |> Phoenix.LiveView.put_flash(:info, "Model deleted")}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("delete model", reason))}
      end
    end)
  end

  # --- Role event handlers ---

  def handle_event("new_role", _params, socket) do
    require_admin(socket, fn ->
      {:noreply,
       Phoenix.Component.assign(socket,
         editing_role: :new,
         role_form: to_form(%{}, as: :role)
       )}
    end)
  end

  def handle_event("cancel_role", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, Phoenix.Component.assign(socket, editing_role: nil)}
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
           Phoenix.Component.assign(socket,
             editing_role: role,
             role_form: to_form(form_data, as: :role),
             role_users: Liteskill.Rbac.list_role_users(role.id),
             role_groups: Liteskill.Rbac.list_role_groups(role.id)
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("load role", reason))}
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
           |> Phoenix.Component.assign(
             rbac_roles: Liteskill.Rbac.list_roles(),
             editing_role: nil
           )
           |> Phoenix.LiveView.put_flash(:info, "Role created")}

        {:error, changeset} ->
          msg = format_changeset(changeset)
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}
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
           |> Phoenix.Component.assign(
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
           |> Phoenix.LiveView.put_flash(:info, "Role updated")}

        {:error, changeset} ->
          msg = format_changeset(changeset)
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, msg)}
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
               |> Phoenix.Component.assign(
                 rbac_roles: Liteskill.Rbac.list_roles(),
                 editing_role: nil
               )
               |> Phoenix.LiveView.put_flash(:info, "Role deleted")}

            {:error, :cannot_delete_system_role} ->
              {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Cannot delete system roles")}

            {:error, reason} ->
              {:noreply,
               Phoenix.LiveView.put_flash(socket, :error, action_error("delete role", reason))}
          end

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("load role", reason))}
      end
    end)
  end

  def handle_event("assign_role_user", %{"email" => email}, socket) do
    require_admin(socket, fn ->
      role = socket.assigns.editing_role

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "User not found")}

        user ->
          case Liteskill.Rbac.assign_role_to_user(user.id, role.id) do
            {:ok, _} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 role_users: Liteskill.Rbac.list_role_users(role.id)
               )}

            {:error, reason} ->
              {:noreply,
               Phoenix.LiveView.put_flash(
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
           Phoenix.Component.assign(socket,
             role_users: Liteskill.Rbac.list_role_users(role.id)
           )}

        {:error, :cannot_remove_root_admin} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             "Cannot remove Instance Admin from root admin"
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
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
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Group not found")}

        group ->
          case Liteskill.Rbac.assign_role_to_group(group.id, role.id) do
            {:ok, _} ->
              {:noreply,
               Phoenix.Component.assign(socket,
                 role_groups: Liteskill.Rbac.list_role_groups(role.id)
               )}

            {:error, reason} ->
              {:noreply,
               Phoenix.LiveView.put_flash(
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
           Phoenix.Component.assign(socket,
             role_groups: Liteskill.Rbac.list_role_groups(role.id)
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             action_error("remove group from role", reason)
           )}
      end
    end)
  end

  # --- RAG Tab Event Handlers ---

  def handle_event("rag_select_model", %{"model_id" => model_id}, socket) do
    require_admin(socket, fn ->
      current_id =
        case socket.assigns.rag_current_model do
          %{id: id} -> id
          _ -> nil
        end

      selected_id = if model_id == "", do: nil, else: model_id

      if selected_id == current_id do
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :info, "Model is already set to this value")}
      else
        {:noreply,
         Phoenix.Component.assign(socket,
           rag_confirm_change: true,
           rag_confirm_input: "",
           rag_selected_model_id: selected_id
         )}
      end
    end)
  end

  def handle_event("rag_cancel_change", _params, socket) do
    {:noreply,
     Phoenix.Component.assign(socket,
       rag_confirm_change: false,
       rag_confirm_input: "",
       rag_selected_model_id: nil
     )}
  end

  def handle_event("rag_confirm_input_change", %{"value" => value}, socket) do
    {:noreply, Phoenix.Component.assign(socket, rag_confirm_input: value)}
  end

  def handle_event("rag_confirm_model_change", %{"confirmation" => confirmation}, socket) do
    require_admin(socket, fn ->
      if confirmation != "I know what this means and I am very sure" do
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Confirmation text does not match")}
      else
        selected_id = socket.assigns.rag_selected_model_id
        user_id = socket.assigns.current_user.id

        case Settings.update_embedding_model(selected_id) do
          {:ok, _settings} ->
            Liteskill.Rag.clear_all_embeddings()

            if selected_id do
              Liteskill.Rag.ReembedWorker.new(%{"user_id" => user_id})
              |> Oban.insert()
            end

            socket =
              socket
              |> load_tab_data(:admin_rag)
              |> Phoenix.LiveView.put_flash(
                :info,
                if(selected_id,
                  do: "Embedding model updated. Re-embedding started.",
                  else: "Embedding model cleared. RAG ingest is now disabled."
                )
              )

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             Phoenix.LiveView.put_flash(
               socket,
               :error,
               action_error("update embedding model", reason)
             )}
        end
      end
    end)
  end

  @doc false
  def build_provider_attrs(params, user_id) do
    with {:ok, provider_config} <- parse_json_config(params["provider_config_json"]) do
      attrs = %{
        name: params["name"],
        provider_type: params["provider_type"],
        provider_config: provider_config,
        instance_wide: params["instance_wide"] == "true",
        status: params["status"] || "active",
        user_id: user_id
      }

      attrs =
        case params["api_key"] do
          nil -> attrs
          "" -> attrs
          key -> Map.put(attrs, :api_key, key)
        end

      {:ok, attrs}
    end
  end

  @doc false
  def build_model_attrs(params, user_id) do
    with {:ok, model_config} <- parse_json_config(params["model_config_json"]) do
      {:ok,
       %{
         name: params["name"],
         provider_id: params["provider_id"],
         model_id: params["model_id"],
         model_type: params["model_type"] || "inference",
         model_config: model_config,
         instance_wide: params["instance_wide"] == "true",
         status: params["status"] || "active",
         input_cost_per_million: parse_decimal(params["input_cost_per_million"]),
         output_cost_per_million: parse_decimal(params["output_cost_per_million"]),
         user_id: user_id
       }}
    end
  end

  @doc false
  def parse_decimal(nil), do: nil
  def parse_decimal(""), do: nil

  def parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> d
      _ -> nil
    end
  end

  @doc false
  def parse_json_config(nil), do: {:ok, %{}}
  def parse_json_config(""), do: {:ok, %{}}

  def parse_json_config(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "Config must be a JSON object, not an array or scalar"}
      {:error, _} -> {:error, "Invalid JSON in config field"}
    end
  end
end
