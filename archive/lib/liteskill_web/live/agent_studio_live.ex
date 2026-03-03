defmodule LiteskillWeb.AgentStudioLive do
  @moduledoc """
  Agent Studio event handlers and helpers, rendered within ChatLive's main area.
  Handles Agents, Teams, Runs, and Schedules pages.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Agents
  alias Liteskill.Chat
  alias Liteskill.LlmModels
  alias Liteskill.McpServers
  alias Liteskill.Runs
  alias Liteskill.Runs.Runner
  alias Liteskill.Schedules
  alias Liteskill.Teams
  alias LiteskillWeb.AgentStudioComponents
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.SharingComponents
  alias LiteskillWeb.SharingLive

  @studio_actions [
    :agent_studio,
    :agents,
    :agent_new,
    :agent_show,
    :agent_edit,
    :teams,
    :team_new,
    :team_show,
    :team_edit,
    :runs,
    :run_new,
    :run_show,
    :run_log_show,
    :schedules,
    :schedule_new,
    :schedule_show
  ]

  def studio_actions, do: @studio_actions
  def studio_action?(action), do: action in @studio_actions

  def studio_assigns do
    [
      studio_agents: [],
      studio_agent: nil,
      studio_teams: [],
      studio_team: nil,
      studio_runs: [],
      studio_run: nil,
      run_usage: nil,
      run_usage_by_model: [],
      studio_schedules: [],
      studio_schedule: nil,
      agent_form: agent_form(),
      team_form: team_form(),
      run_form: run_form(),
      schedule_form: schedule_form(),
      editing_agent: nil,
      editing_team: nil,
      confirm_delete_agent_id: nil,
      confirm_delete_team_id: nil,
      confirm_delete_run_id: nil,
      confirm_delete_schedule_id: nil
    ]
  end

  def agent_form(data \\ %{}) do
    Phoenix.Component.to_form(
      Map.merge(
        %{
          "name" => "",
          "description" => "",
          "backstory" => "",
          "opinions" => [],
          "system_prompt" => "",
          "strategy" => "react",
          "llm_model_id" => "",
          "role_id" => ""
        },
        data
      ),
      as: :agent
    )
  end

  def team_form(data \\ %{}) do
    Phoenix.Component.to_form(
      Map.merge(
        %{
          "name" => "",
          "description" => "",
          "shared_context" => "",
          "default_topology" => "pipeline",
          "aggregation_strategy" => "last"
        },
        data
      ),
      as: :team
    )
  end

  def run_form(data \\ %{}) do
    Phoenix.Component.to_form(
      Map.merge(
        %{
          "name" => "",
          "description" => "",
          "prompt" => "",
          "topology" => "pipeline",
          "team_definition_id" => "",
          "timeout_minutes" => "60",
          "max_iterations" => "50",
          "cost_limit" => ""
        },
        data
      ),
      as: :run
    )
  end

  def schedule_form(data \\ %{}) do
    Phoenix.Component.to_form(
      Map.merge(
        %{
          "name" => "",
          "description" => "",
          "cron_expression" => "",
          "timezone" => "UTC",
          "prompt" => "",
          "topology" => "pipeline",
          "team_definition_id" => ""
        },
        data
      ),
      as: :schedule
    )
  end

  # --- Apply Actions ---

  defp reset_common(socket) do
    assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: []
    )
  end

  # Agent Studio Landing

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)
    user = socket.assigns.current_user
    available_llm_models = LlmModels.list_active_models(user.id, model_type: "inference")
    available_roles = Liteskill.Rbac.list_roles()

    {:ok,
     socket
     |> assign(studio_assigns())
     |> assign(
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(user.id),
       single_user_mode: Liteskill.SingleUser.enabled?(),
       available_llm_models: available_llm_models,
       available_roles: available_roles,
       # Sharing modal state
       show_sharing: false,
       sharing_entity_type: nil,
       sharing_entity_id: nil,
       sharing_acls: [],
       sharing_user_search_results: [],
       sharing_user_search_query: "",
       sharing_groups: [],
       sharing_error: nil
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, action, params) when action in @studio_actions do
    apply_studio_action(socket, action, params)
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
        <%= if @live_action == :agent_studio do %>
          <AgentStudioComponents.agent_studio_landing sidebar_open={@sidebar_open} />
        <% end %>
        <%= if @live_action == :agents do %>
          <AgentStudioComponents.agents_page
            agents={@studio_agents}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_agent_id={@confirm_delete_agent_id}
          />
        <% end %>
        <%= if @live_action in [:agent_new, :agent_edit] do %>
          <AgentStudioComponents.agent_form_page
            form={@agent_form}
            editing={@editing_agent}
            available_models={@available_llm_models}
            available_roles={@available_roles}
            all_mcp_servers={assigns[:all_mcp_servers] || []}
            assigned_server_ids={assigns[:assigned_server_ids] || MapSet.new()}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :agent_show && @studio_agent do %>
          <AgentStudioComponents.agent_show_page
            agent={@studio_agent}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :teams do %>
          <AgentStudioComponents.teams_page
            teams={@studio_teams}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_team_id={@confirm_delete_team_id}
          />
        <% end %>
        <%= if @live_action in [:team_new, :team_edit] do %>
          <AgentStudioComponents.team_form_page
            form={@team_form}
            editing={@editing_team}
            available_agents={assigns[:available_agents] || []}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :team_show && @studio_team do %>
          <AgentStudioComponents.team_show_page
            team={@studio_team}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :runs do %>
          <AgentStudioComponents.runs_page
            runs={@studio_runs}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_run_id={@confirm_delete_run_id}
          />
        <% end %>
        <%= if @live_action == :run_new do %>
          <AgentStudioComponents.run_form_page
            form={@run_form}
            teams={@studio_teams}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :run_show && @studio_run do %>
          <AgentStudioComponents.run_show_page
            run={@studio_run}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            run_usage={@run_usage}
            run_usage_by_model={@run_usage_by_model}
          />
        <% end %>
        <%= if @live_action == :run_log_show do %>
          <AgentStudioComponents.run_log_show_page
            run={@studio_run}
            log={@studio_log}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :schedules do %>
          <AgentStudioComponents.schedules_page
            schedules={@studio_schedules}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_schedule_id={@confirm_delete_schedule_id}
          />
        <% end %>
        <%= if @live_action == :schedule_new do %>
          <AgentStudioComponents.schedule_form_page
            form={@schedule_form}
            teams={@studio_teams}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action == :schedule_show && @studio_schedule do %>
          <AgentStudioComponents.schedule_show_page
            schedule={@studio_schedule}
            sidebar_open={@sidebar_open}
          />
        <% end %>

        <SharingComponents.sharing_modal
          show={@show_sharing}
          entity_type={@sharing_entity_type}
          entity_id={@sharing_entity_id}
          acls={@sharing_acls}
          user_search_results={@sharing_user_search_results}
          user_search_query={@sharing_user_search_query}
          groups={@sharing_groups}
          error={@sharing_error}
          current_user_id={@current_user.id}
        />
      </main>
    </div>
    """
  end

  def apply_studio_action(socket, :agent_studio, _params) do
    socket
    |> reset_common()
    |> assign(page_title: "Agent Studio")
  end

  # Agents

  def apply_studio_action(socket, :agents, _params) do
    user_id = socket.assigns.current_user.id
    agents = Agents.list_agents(user_id)

    socket
    |> reset_common()
    |> assign(
      studio_agents: agents,
      confirm_delete_agent_id: nil,
      page_title: "Agents"
    )
  end

  def apply_studio_action(socket, :agent_new, _params) do
    socket
    |> reset_common()
    |> assign(
      agent_form: agent_form(),
      editing_agent: nil,
      page_title: "New Agent"
    )
  end

  def apply_studio_action(socket, :agent_show, %{"agent_id" => agent_id}) do
    user_id = socket.assigns.current_user.id

    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        socket
        |> reset_common()
        |> assign(studio_agent: agent, page_title: agent.name)

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load agent", reason))
        |> push_navigate(to: "/agents")
    end
  end

  def apply_studio_action(socket, :agent_edit, %{"agent_id" => agent_id}) do
    user_id = socket.assigns.current_user.id

    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        all_mcp_servers = McpServers.list_servers(user_id)
        assigned_server_ids = compute_assigned_server_ids(agent)

        current_role_id =
          case Liteskill.Rbac.list_agent_roles(agent.id) do
            [role | _] -> role.id
            [] -> ""
          end

        socket
        |> reset_common()
        |> assign(
          editing_agent: agent,
          all_mcp_servers: all_mcp_servers,
          assigned_server_ids: assigned_server_ids,
          agent_form:
            agent_form(%{
              "name" => agent.name || "",
              "description" => agent.description || "",
              "backstory" => agent.backstory || "",
              "opinions" => encode_opinions(agent.opinions),
              "system_prompt" => agent.system_prompt || "",
              "strategy" => agent.strategy,
              "llm_model_id" => agent.llm_model_id || "",
              "role_id" => current_role_id
            }),
          page_title: "Edit #{agent.name}"
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load agent", reason))
        |> push_navigate(to: "/agents")
    end
  end

  # Teams

  def apply_studio_action(socket, :teams, _params) do
    user_id = socket.assigns.current_user.id
    teams = Teams.list_teams(user_id)

    socket
    |> reset_common()
    |> assign(
      studio_teams: teams,
      confirm_delete_team_id: nil,
      page_title: "Teams"
    )
  end

  def apply_studio_action(socket, :team_new, _params) do
    socket
    |> reset_common()
    |> assign(
      team_form: team_form(),
      editing_team: nil,
      page_title: "New Team"
    )
  end

  def apply_studio_action(socket, :team_show, %{"team_id" => team_id}) do
    user_id = socket.assigns.current_user.id

    case Teams.get_team(team_id, user_id) do
      {:ok, team} ->
        socket
        |> reset_common()
        |> assign(studio_team: team, page_title: team.name)

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load team", reason))
        |> push_navigate(to: "/teams")
    end
  end

  def apply_studio_action(socket, :team_edit, %{"team_id" => team_id}) do
    user_id = socket.assigns.current_user.id

    case Teams.get_team(team_id, user_id) do
      {:ok, team} ->
        all_agents = Agents.list_agents(user_id)
        member_agent_ids = MapSet.new(team.team_members, & &1.agent_definition_id)
        available_agents = Enum.reject(all_agents, &MapSet.member?(member_agent_ids, &1.id))

        socket
        |> reset_common()
        |> assign(
          editing_team: team,
          available_agents: available_agents,
          team_form:
            team_form(%{
              "name" => team.name || "",
              "description" => team.description || "",
              "shared_context" => team.shared_context || "",
              "default_topology" => team.default_topology,
              "aggregation_strategy" => team.aggregation_strategy
            }),
          page_title: "Edit #{team.name}"
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load team", reason))
        |> push_navigate(to: "/teams")
    end
  end

  # Runs

  def apply_studio_action(socket, :runs, _params) do
    user_id = socket.assigns.current_user.id
    runs = Runs.list_runs(user_id)

    socket
    |> reset_common()
    |> assign(
      studio_runs: runs,
      confirm_delete_run_id: nil,
      page_title: "Runs"
    )
  end

  def apply_studio_action(socket, :run_new, _params) do
    user_id = socket.assigns.current_user.id
    teams = Teams.list_teams(user_id)

    socket
    |> reset_common()
    |> assign(
      run_form: run_form(),
      studio_teams: teams,
      page_title: "New Run"
    )
  end

  def apply_studio_action(socket, :run_show, %{"run_id" => run_id}) do
    user_id = socket.assigns.current_user.id

    maybe_unsubscribe_run(socket)

    case Runs.get_run(run_id, user_id) do
      {:ok, run} ->
        Runs.subscribe(run.id)
        run_usage = Liteskill.Usage.usage_by_run(run.id)
        run_usage_by_model = Liteskill.Usage.usage_by_run_and_model(run.id)

        socket
        |> reset_common()
        |> assign(
          studio_run: run,
          run_usage: run_usage,
          run_usage_by_model: run_usage_by_model,
          page_title: run.name
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load run", reason))
        |> push_navigate(to: "/runs")
    end
  end

  def apply_studio_action(socket, :run_log_show, %{"run_id" => run_id, "log_id" => log_id}) do
    user_id = socket.assigns.current_user.id

    with {:ok, run} <- Runs.get_run(run_id, user_id),
         {:ok, log} <- Runs.get_log(log_id, user_id) do
      socket
      |> reset_common()
      |> assign(
        studio_run: run,
        studio_log: log,
        page_title: "Log: #{log.step}"
      )
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load log entry", reason))
        |> push_navigate(to: "/runs")
    end
  end

  # Schedules

  def apply_studio_action(socket, :schedules, _params) do
    user_id = socket.assigns.current_user.id
    schedules = Schedules.list_schedules(user_id)

    socket
    |> reset_common()
    |> assign(
      studio_schedules: schedules,
      confirm_delete_schedule_id: nil,
      page_title: "Schedules"
    )
  end

  def apply_studio_action(socket, :schedule_new, _params) do
    user_id = socket.assigns.current_user.id
    teams = Teams.list_teams(user_id)

    socket
    |> reset_common()
    |> assign(
      schedule_form: schedule_form(),
      studio_teams: teams,
      page_title: "New Schedule"
    )
  end

  def apply_studio_action(socket, :schedule_show, %{"schedule_id" => schedule_id}) do
    user_id = socket.assigns.current_user.id

    case Schedules.get_schedule(schedule_id, user_id) do
      {:ok, schedule} ->
        socket
        |> reset_common()
        |> assign(studio_schedule: schedule, page_title: schedule.name)

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load schedule", reason))
        |> push_navigate(to: "/schedules")
    end
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

  @sharing_events SharingLive.sharing_events()

  @impl true
  def handle_event(event, params, socket) when event in @sharing_events do
    SharingLive.handle_event(event, params, socket)
  end

  # Agent events

  @impl true
  def handle_event("save_agent", %{"agent" => params}, socket) do
    user_id = socket.assigns.current_user.id
    params = decode_opinions(params)

    result =
      if socket.assigns.editing_agent do
        Agents.update_agent(socket.assigns.editing_agent.id, user_id, params)
      else
        Agents.create_agent(Map.put(params, "user_id", user_id))
      end

    case result do
      {:ok, agent} ->
        msg = if socket.assigns.editing_agent, do: "Agent updated", else: "Agent created"

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: "/agents/#{agent.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset(changeset))
         |> assign(agent_form: agent_form(params))}
    end
  end

  @impl true
  def handle_event("validate_agent", %{"agent" => params}, socket) do
    params = normalize_opinion_params(params)
    {:noreply, assign(socket, agent_form: agent_form(params))}
  end

  @impl true
  def handle_event("select_strategy", %{"strategy" => strategy}, socket) do
    current = socket.assigns.agent_form.params

    {:noreply, assign(socket, agent_form: agent_form(%{current | "strategy" => strategy}))}
  end

  @impl true
  def handle_event("add_opinion", _params, socket) do
    current = socket.assigns.agent_form.params
    opinions = (current["opinions"] || []) ++ [%{"key" => "", "value" => ""}]

    {:noreply, assign(socket, agent_form: agent_form(%{current | "opinions" => opinions}))}
  end

  @impl true
  def handle_event("remove_opinion", %{"index" => idx}, socket) do
    {idx, _} = Integer.parse(idx)
    current = socket.assigns.agent_form.params
    opinions = List.delete_at(current["opinions"] || [], idx)

    {:noreply, assign(socket, agent_form: agent_form(%{current | "opinions" => opinions}))}
  end

  @impl true
  def handle_event("confirm_delete_agent", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_agent_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_agent", _params, socket) do
    {:noreply, assign(socket, confirm_delete_agent_id: nil)}
  end

  @impl true
  def handle_event("delete_agent", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Agents.delete_agent(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent deleted")
         |> push_navigate(to: "/agents")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete agent", reason))}
    end
  end

  @impl true
  def handle_event("toggle_agent_tool", %{"server-id" => "builtin:" <> _ = id}, socket) do
    agent = socket.assigns.editing_agent
    existing = get_in(agent.config, ["builtin_server_ids"]) || []

    updated =
      if id in existing, do: List.delete(existing, id), else: existing ++ [id]

    config = Map.put(agent.config || %{}, "builtin_server_ids", updated)

    case Agents.update_agent(agent.id, socket.assigns.current_user.id, %{config: config}) do
      {:ok, agent} ->
        {:noreply,
         assign(socket,
           editing_agent: agent,
           assigned_server_ids: compute_assigned_server_ids(agent)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("toggle server", reason))}
    end
  end

  @impl true
  def handle_event("toggle_agent_tool", %{"server-id" => server_id}, socket) do
    agent = socket.assigns.editing_agent
    assigned = socket.assigns.assigned_server_ids

    result =
      if MapSet.member?(assigned, server_id) do
        Agents.revoke_tool_access(agent.id, server_id, socket.assigns.current_user.id)
      else
        Agents.grant_tool_access(agent.id, server_id, socket.assigns.current_user.id)
      end

    case result do
      {:ok, _} ->
        {:ok, agent} = Agents.get_agent(agent.id, socket.assigns.current_user.id)

        {:noreply,
         assign(socket,
           editing_agent: agent,
           assigned_server_ids: compute_assigned_server_ids(agent)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("toggle server", reason))}
    end
  end

  # Team events

  @impl true
  def handle_event("save_team", %{"team" => params}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      if socket.assigns.editing_team do
        Teams.update_team(socket.assigns.editing_team.id, user_id, params)
      else
        Teams.create_team(Map.put(params, "user_id", user_id))
      end

    case result do
      {:ok, team} ->
        msg = if socket.assigns.editing_team, do: "Team updated", else: "Team created"

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: "/teams/#{team.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset(changeset))
         |> assign(team_form: team_form(params))}
    end
  end

  @impl true
  def handle_event("confirm_delete_team", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_team_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_team", _params, socket) do
    {:noreply, assign(socket, confirm_delete_team_id: nil)}
  end

  @impl true
  def handle_event("delete_team", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Teams.delete_team(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Team deleted")
         |> push_navigate(to: "/teams")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete team", reason))}
    end
  end

  @impl true
  def handle_event("add_team_member", %{"agent_id" => agent_id}, socket) do
    team = socket.assigns.editing_team
    user_id = socket.assigns.current_user.id

    case Teams.add_member(team.id, agent_id, user_id) do
      {:ok, _member} ->
        {:ok, team} = Teams.get_team(team.id, socket.assigns.current_user.id)
        member_agent_ids = MapSet.new(team.team_members, & &1.agent_definition_id)

        available_agents =
          Enum.reject(socket.assigns.available_agents, &MapSet.member?(member_agent_ids, &1.id))

        {:noreply,
         assign(socket,
           editing_team: team,
           available_agents: available_agents
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("add team member", reason))}
    end
  end

  @impl true
  def handle_event("remove_team_member", %{"agent_id" => agent_id}, socket) do
    team = socket.assigns.editing_team
    user_id = socket.assigns.current_user.id

    case Teams.remove_member(team.id, agent_id, user_id) do
      {:ok, _} ->
        {:ok, team} = Teams.get_team(team.id, socket.assigns.current_user.id)
        all_agents = Agents.list_agents(socket.assigns.current_user.id)
        member_agent_ids = MapSet.new(team.team_members, & &1.agent_definition_id)

        available_agents =
          Enum.reject(all_agents, &MapSet.member?(member_agent_ids, &1.id))

        {:noreply,
         assign(socket,
           editing_team: team,
           available_agents: available_agents
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("remove team member", reason))}
    end
  end

  # Run events

  @impl true
  def handle_event("save_run", %{"run" => form_params}, socket) do
    user_id = socket.assigns.current_user.id

    params =
      form_params
      |> Map.put("user_id", user_id)
      |> parse_timeout_param()
      |> parse_cost_limit_param()

    case Runs.create_run(params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run created")
         |> push_navigate(to: "/runs/#{run.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset(changeset))
         |> assign(run_form: run_form(form_params))}
    end
  end

  @impl true
  def handle_event("start_run", _params, socket) do
    user_id = socket.assigns.current_user.id
    run = socket.assigns.studio_run

    if run.status == "pending" do
      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        Runner.run(run.id, user_id)
      end)

      {:noreply,
       socket
       |> put_flash(:info, "Run started.")
       |> assign(studio_run: %{run | status: "running"})}
    else
      {:noreply, put_flash(socket, :error, "Run can only be started when pending")}
    end
  end

  @impl true
  def handle_event("rerun", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, original} <- Runs.get_run(id, user_id),
         {:ok, new_run} <-
           Runs.create_run(%{
             name: original.name,
             description: original.description,
             prompt: original.prompt,
             topology: original.topology,
             team_definition_id: original.team_definition_id,
             timeout_ms: original.timeout_ms,
             max_iterations: original.max_iterations,
             cost_limit: original.cost_limit,
             user_id: user_id
           }) do
      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        Runner.run(new_run.id, user_id)
      end)

      {:noreply,
       socket
       |> put_flash(:info, "Rerun started.")
       |> push_navigate(to: "/runs/#{new_run.id}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("rerun", reason))}
    end
  end

  @impl true
  def handle_event("retry_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.get_run(id, user_id) do
      {:ok, %{status: status} = run} when status in ["failed", "cancelled"] ->
        Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
          Runner.run(run.id, user_id)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Retrying run...")
         |> assign(studio_run: %{run | status: "running"})}

      {:ok, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only failed or cancelled runs can be retried"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("retry run", reason))}
    end
  end

  @impl true
  def handle_event("cancel_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.cancel_run(id, user_id) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run cancelled")
         |> assign(studio_run: Runs.get_run!(run.id))}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, action_error("cancel run", :not_running))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("cancel run", reason))}
    end
  end

  @impl true
  def handle_event("confirm_delete_run", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_run_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_run", _params, socket) do
    {:noreply, assign(socket, confirm_delete_run_id: nil)}
  end

  @impl true
  def handle_event("delete_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.delete_run(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run deleted")
         |> push_navigate(to: "/runs")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete run", reason))}
    end
  end

  # Schedule events

  @impl true
  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.create_schedule(Map.put(params, "user_id", user_id)) do
      {:ok, schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Schedule created")
         |> push_navigate(to: "/schedules/#{schedule.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset(changeset))
         |> assign(schedule_form: schedule_form(params))}
    end
  end

  @impl true
  def handle_event("toggle_schedule", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.toggle_schedule(id, user_id) do
      {:ok, _} ->
        schedules = Schedules.list_schedules(user_id)
        {:noreply, assign(socket, studio_schedules: schedules)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("toggle schedule", reason))}
    end
  end

  @impl true
  def handle_event("confirm_delete_schedule", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_schedule_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_schedule", _params, socket) do
    {:noreply, assign(socket, confirm_delete_schedule_id: nil)}
  end

  @impl true
  def handle_event("delete_schedule", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.delete_schedule(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Schedule deleted")
         |> push_navigate(to: "/schedules")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete schedule", reason))}
    end
  end

  # --- Helpers ---

  defp encode_opinions(nil), do: []
  defp encode_opinions(map) when map == %{}, do: []

  defp encode_opinions(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> %{"key" => to_string(k), "value" => to_string(v)} end)
  end

  defp decode_opinions(%{"opinions" => entries} = params) when is_map(entries) do
    opinions =
      entries
      |> Enum.sort_by(fn {idx, _} -> elem(Integer.parse(idx), 0) end)
      |> Enum.reduce(%{}, fn {_idx, %{"key" => k, "value" => v}}, acc ->
        key = String.trim(k)
        if key == "", do: acc, else: Map.put(acc, key, String.trim(v))
      end)

    Map.put(params, "opinions", opinions)
  end

  defp decode_opinions(params), do: params

  defp normalize_opinion_params(%{"opinions" => entries} = params) when is_map(entries) do
    opinions =
      entries
      |> Enum.sort_by(fn {idx, _} -> elem(Integer.parse(idx), 0) end)
      |> Enum.map(fn {_idx, entry} -> entry end)

    %{params | "opinions" => opinions}
  end

  defp normalize_opinion_params(params), do: params

  defp parse_timeout_param(%{"timeout_minutes" => val} = params) do
    params = Map.delete(params, "timeout_minutes")

    case Integer.parse(to_string(val)) do
      {minutes, _} when minutes > 0 -> Map.put(params, "timeout_ms", minutes * 60_000)
      _ -> params
    end
  end

  defp parse_timeout_param(params), do: params

  defp parse_cost_limit_param(%{"cost_limit" => ""} = params), do: Map.delete(params, "cost_limit")

  defp parse_cost_limit_param(%{"cost_limit" => val} = params) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> %{params | "cost_limit" => d}
      _ -> Map.delete(params, "cost_limit")
    end
  end

  defp parse_cost_limit_param(params), do: params

  defp compute_assigned_server_ids(agent) do
    db_ids = Agents.list_tool_server_ids(agent.id)
    builtin_ids = get_in(agent.config, ["builtin_server_ids"]) || []
    MapSet.new(db_ids ++ builtin_ids)
  end

  # --- Run PubSub ---

  def handle_run_info({:run_updated, run}, socket) do
    run_usage = Liteskill.Usage.usage_by_run(run.id)
    run_usage_by_model = Liteskill.Usage.usage_by_run_and_model(run.id)

    {:noreply,
     assign(socket,
       studio_run: run,
       run_usage: run_usage,
       run_usage_by_model: run_usage_by_model
     )}
  end

  def handle_run_info({:run_log_added, _log}, socket) do
    case socket.assigns.studio_run do
      nil ->
        {:noreply, socket}

      run ->
        user_id = socket.assigns.current_user.id

        case Runs.get_run(run.id, user_id) do
          {:ok, refreshed} ->
            run_usage = Liteskill.Usage.usage_by_run(run.id)
            run_usage_by_model = Liteskill.Usage.usage_by_run_and_model(run.id)

            {:noreply,
             assign(socket,
               studio_run: refreshed,
               run_usage: run_usage,
               run_usage_by_model: run_usage_by_model
             )}

          _ ->
            {:noreply, socket}
        end
    end
  end

  def maybe_unsubscribe_run(socket) do
    case socket.assigns[:studio_run] do
      %{id: id} when not is_nil(id) -> Runs.unsubscribe(id)
      _ -> :ok
    end
  end

  # --- handle_info callbacks ---

  @impl true
  def handle_info({:run_updated, _run} = msg, socket) do
    handle_run_info(msg, socket)
  end

  @impl true
  def handle_info({:run_log_added, _log} = msg, socket) do
    handle_run_info(msg, socket)
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
