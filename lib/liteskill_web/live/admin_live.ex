defmodule LiteskillWeb.AdminLive do
  @moduledoc """
  Admin panel LiveView. Thin dispatcher that delegates tab-specific logic
  to `LiteskillWeb.AdminLive.*Tab` modules.
  """

  use LiteskillWeb, :live_view

  alias LiteskillWeb.AdminLive.GroupsTab
  alias LiteskillWeb.AdminLive.Helpers
  alias LiteskillWeb.AdminLive.ModelsTab
  alias LiteskillWeb.AdminLive.ProvidersTab
  alias LiteskillWeb.AdminLive.RagTab
  alias LiteskillWeb.AdminLive.RolesTab
  alias LiteskillWeb.AdminLive.ServerTab
  alias LiteskillWeb.AdminLive.UsageTab
  alias LiteskillWeb.AdminLive.UsersTab
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.ProfileLive
  alias LiteskillWeb.SettingsLive

  # --- Public API (used by Layouts, ProfileLive, SetupLive, tests) ---

  @admin_actions [
    :admin_usage,
    :admin_servers,
    :admin_users,
    :admin_groups,
    :admin_providers,
    :admin_models,
    :admin_roles,
    :admin_rag
  ]

  def admin_action?(action), do: action in @admin_actions

  defdelegate build_provider_attrs(params, user_id), to: Helpers
  defdelegate build_model_attrs(params, user_id), to: Helpers
  defdelegate parse_decimal(val), to: Helpers
  defdelegate parse_json_config(json), to: Helpers

  def admin_assigns do
    UsageTab.assigns() ++
      ServerTab.assigns() ++
      UsersTab.assigns() ++
      GroupsTab.assigns() ++
      ProvidersTab.assigns() ++
      ModelsTab.assigns() ++
      RolesTab.assigns() ++
      RagTab.assigns()
  end

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations =
      if connected?(socket),
        do: Liteskill.Chat.list_conversations(socket.assigns.current_user.id),
        else: []

    {:ok,
     socket
     |> assign(admin_assigns())
     |> assign(ProfileLive.profile_assigns())
     |> assign(
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       single_user_mode: Liteskill.SingleUser.enabled?(),
       has_admin_access: true,
       settings_mode: false
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, action) when action in @admin_actions do
    apply_admin_action(socket, action, socket.assigns.current_user)
  end

  defp apply_action(socket, :settings_account) do
    socket
    |> assign(settings_mode: true)
    |> ProfileLive.apply_profile_action(:info, socket.assigns.current_user)
  end

  defp apply_action(socket, action) do
    admin_action = SettingsLive.settings_to_admin_action(action)

    if admin_action do
      socket
      |> assign(settings_mode: true)
      |> apply_admin_action(admin_action, socket.assigns.current_user)
    else
      push_navigate(socket, to: ~p"/admin")
    end
  end

  def apply_admin_action(socket, action, user) do
    if Liteskill.Rbac.has_any_admin_permission?(user.id) do
      load_tab_data(socket, action)
    else
      push_navigate(socket, to: ~p"/profile")
    end
  end

  # --- Load dispatch ---

  defp load_tab_data(socket, :admin_usage), do: UsageTab.load_data(socket)
  defp load_tab_data(socket, :admin_servers), do: ServerTab.load_data(socket)
  defp load_tab_data(socket, :admin_users), do: UsersTab.load_data(socket)
  defp load_tab_data(socket, :admin_groups), do: GroupsTab.load_data(socket)
  defp load_tab_data(socket, :admin_providers), do: ProvidersTab.load_data(socket)
  defp load_tab_data(socket, :admin_models), do: ModelsTab.load_data(socket)
  defp load_tab_data(socket, :admin_roles), do: RolesTab.load_data(socket)
  defp load_tab_data(socket, :admin_rag), do: RagTab.load_data(socket)

  # --- Render ---

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
        <%= if @live_action == :settings_account do %>
          <ProfileLive.profile
            live_action={:info}
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
            settings_mode={true}
            settings_action={@live_action}
          />
        <% else %>
          <.admin_panel
            live_action={
              if(@settings_mode,
                do: SettingsLive.settings_to_admin_action(@live_action),
                else: @live_action
              )
            }
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            single_user_mode={@single_user_mode}
            profile_users={@profile_users}
            profile_groups={@profile_groups}
            group_detail={@group_detail}
            group_members={@group_members}
            temp_password_user_id={@temp_password_user_id}
            llm_models={@llm_models}
            editing_llm_model={@editing_llm_model}
            llm_model_form={@llm_model_form}
            llm_providers={@llm_providers}
            editing_llm_provider={@editing_llm_provider}
            llm_provider_form={@llm_provider_form}
            server_settings={@server_settings}
            invitations={@invitations}
            new_invitation_url={@new_invitation_url}
            admin_usage_data={@admin_usage_data}
            admin_usage_period={@admin_usage_period}
            rbac_roles={@rbac_roles}
            editing_role={@editing_role}
            role_form={@role_form}
            role_users={@role_users}
            role_groups={@role_groups}
            role_user_search={@role_user_search}
            rag_embedding_models={@rag_embedding_models}
            rag_current_model={@rag_current_model}
            rag_stats={@rag_stats}
            rag_confirm_change={@rag_confirm_change}
            rag_confirm_input={@rag_confirm_input}
            rag_selected_model_id={@rag_selected_model_id}
            rag_reembed_in_progress={@rag_reembed_in_progress}
            or_search={@or_search}
            or_results={@or_results}
            or_loading={@or_loading}
            embed_results_all={@embed_results_all}
            embed_search={@embed_search}
            embed_results={@embed_results}
            settings_mode={@settings_mode}
            settings_action={@live_action}
          />
        <% end %>
      </main>
    </div>
    """
  end

  # --- Admin Panel Component ---

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
  attr :or_search, :string, default: ""
  attr :or_results, :list, default: []
  attr :or_loading, :boolean, default: false
  attr :embed_results_all, :list, default: []
  attr :embed_search, :string, default: ""
  attr :embed_results, :list, default: []
  attr :settings_mode, :boolean, default: false
  attr :settings_action, :atom, default: nil
  attr :single_user_mode, :boolean, default: false

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
        <h1 class="text-lg font-semibold">
          {if @settings_mode || @single_user_mode, do: "Settings", else: "Admin"}
        </h1>
      </div>
    </header>

    <div class="border-b border-base-300 px-4 flex-shrink-0">
      <%= if @settings_mode do %>
        <SettingsLive.settings_tab_bar active={@settings_action} />
      <% else %>
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
            :if={!@single_user_mode}
            label="Users"
            to={~p"/admin/users"}
            active={@live_action == :admin_users}
          />
          <.tab_link
            :if={!@single_user_mode}
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
      <% end %>
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

  # --- Render dispatch ---

  defp render_tab(%{live_action: :admin_usage} = a), do: UsageTab.render_tab(a)
  defp render_tab(%{live_action: :admin_servers} = a), do: ServerTab.render_tab(a)
  defp render_tab(%{live_action: :admin_users} = a), do: UsersTab.render_tab(a)
  defp render_tab(%{live_action: :admin_groups} = a), do: GroupsTab.render_tab(a)
  defp render_tab(%{live_action: :admin_providers} = a), do: ProvidersTab.render_tab(a)
  defp render_tab(%{live_action: :admin_models} = a), do: ModelsTab.render_tab(a)
  defp render_tab(%{live_action: :admin_roles} = a), do: RolesTab.render_tab(a)
  defp render_tab(%{live_action: :admin_rag} = a), do: RagTab.render_tab(a)

  # --- Event dispatch ---

  @usage_events ~w(admin_usage_period)
  @server_events ~w(toggle_registration toggle_allow_private_mcp_urls update_mcp_cost_limit)
  @user_events ~w(promote_user demote_user show_temp_password_form cancel_temp_password set_temp_password create_invitation revoke_invitation)
  @group_events ~w(create_group admin_delete_group view_group admin_add_member admin_remove_member)
  @provider_events ~w(new_llm_provider cancel_llm_provider create_llm_provider edit_llm_provider update_llm_provider delete_llm_provider)
  @model_events ~w(new_llm_model cancel_llm_model create_llm_model edit_llm_model update_llm_model delete_llm_model)
  @role_events ~w(new_role cancel_role edit_role create_role update_role delete_role assign_role_user remove_role_user assign_role_group remove_role_group)
  @rag_events ~w(rag_select_model rag_cancel_change rag_confirm_input_change rag_confirm_model_change)
  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

  @impl true
  def handle_event(e, p, s) when e in @usage_events, do: UsageTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @server_events, do: ServerTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @user_events, do: UsersTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @group_events, do: GroupsTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @provider_events, do: ProvidersTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @model_events, do: ModelsTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @role_events, do: RolesTab.handle_event(e, p, s)
  @impl true
  def handle_event(e, p, s) when e in @rag_events, do: RagTab.handle_event(e, p, s)

  # --- Profile Event Delegation (for settings_account) ---

  @profile_events ~w(change_password set_accent_color
    user_new_provider user_cancel_provider user_create_provider
    user_edit_provider user_update_provider user_delete_provider
    user_new_model user_cancel_model user_create_model
    user_edit_model user_update_model user_delete_model)

  @impl true
  def handle_event(event, params, socket) when event in @profile_events do
    ProfileLive.handle_event(event, params, socket)
  end

  # --- handle_info callbacks ---

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
