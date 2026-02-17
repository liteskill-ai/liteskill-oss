defmodule LiteskillWeb.AgentStudioLive do
  @moduledoc """
  Agent Studio event handlers and helpers, rendered within ChatLive's main area.
  Handles Agents, Teams, Runs, and Schedules pages.
  """

  use LiteskillWeb, :html

  alias Liteskill.Agents
  alias Liteskill.Runs
  alias Liteskill.Runs.Runner
  alias Liteskill.McpServers
  alias Liteskill.Schedules
  alias Liteskill.Teams

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
          "llm_model_id" => ""
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
    Phoenix.Component.assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: []
    )
  end

  # Agent Studio Landing

  def apply_studio_action(socket, :agent_studio, _params) do
    socket
    |> reset_common()
    |> Phoenix.Component.assign(page_title: "Agent Studio")
  end

  # Agents

  def apply_studio_action(socket, :agents, _params) do
    user_id = socket.assigns.current_user.id
    agents = Agents.list_agents(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
      studio_agents: agents,
      confirm_delete_agent_id: nil,
      page_title: "Agents"
    )
  end

  def apply_studio_action(socket, :agent_new, _params) do
    socket
    |> reset_common()
    |> Phoenix.Component.assign(
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
        |> Phoenix.Component.assign(studio_agent: agent, page_title: agent.name)

      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load agent", reason))
        |> Phoenix.LiveView.push_navigate(to: "/agents")
    end
  end

  def apply_studio_action(socket, :agent_edit, %{"agent_id" => agent_id}) do
    user_id = socket.assigns.current_user.id

    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        available_mcp_servers = compute_available_servers(user_id, agent)

        socket
        |> reset_common()
        |> Phoenix.Component.assign(
          editing_agent: agent,
          available_mcp_servers: available_mcp_servers,
          agent_form:
            agent_form(%{
              "name" => agent.name || "",
              "description" => agent.description || "",
              "backstory" => agent.backstory || "",
              "opinions" => encode_opinions(agent.opinions),
              "system_prompt" => agent.system_prompt || "",
              "strategy" => agent.strategy,
              "llm_model_id" => agent.llm_model_id || ""
            }),
          page_title: "Edit #{agent.name}"
        )

      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load agent", reason))
        |> Phoenix.LiveView.push_navigate(to: "/agents")
    end
  end

  # Teams

  def apply_studio_action(socket, :teams, _params) do
    user_id = socket.assigns.current_user.id
    teams = Teams.list_teams(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
      studio_teams: teams,
      confirm_delete_team_id: nil,
      page_title: "Teams"
    )
  end

  def apply_studio_action(socket, :team_new, _params) do
    socket
    |> reset_common()
    |> Phoenix.Component.assign(
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
        |> Phoenix.Component.assign(studio_team: team, page_title: team.name)

      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load team", reason))
        |> Phoenix.LiveView.push_navigate(to: "/teams")
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
        |> Phoenix.Component.assign(
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
        |> Phoenix.LiveView.put_flash(:error, action_error("load team", reason))
        |> Phoenix.LiveView.push_navigate(to: "/teams")
    end
  end

  # Runs

  def apply_studio_action(socket, :runs, _params) do
    user_id = socket.assigns.current_user.id
    runs = Runs.list_runs(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
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
    |> Phoenix.Component.assign(
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
        |> Phoenix.Component.assign(
          studio_run: run,
          run_usage: run_usage,
          run_usage_by_model: run_usage_by_model,
          page_title: run.name
        )

      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load run", reason))
        |> Phoenix.LiveView.push_navigate(to: "/runs")
    end
  end

  def apply_studio_action(socket, :run_log_show, %{
        "run_id" => run_id,
        "log_id" => log_id
      }) do
    user_id = socket.assigns.current_user.id

    with {:ok, run} <- Runs.get_run(run_id, user_id),
         {:ok, log} <- Runs.get_log(log_id, user_id) do
      socket
      |> reset_common()
      |> Phoenix.Component.assign(
        studio_run: run,
        studio_log: log,
        page_title: "Log: #{log.step}"
      )
    else
      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load log entry", reason))
        |> Phoenix.LiveView.push_navigate(to: "/runs")
    end
  end

  # Schedules

  def apply_studio_action(socket, :schedules, _params) do
    user_id = socket.assigns.current_user.id
    schedules = Schedules.list_schedules(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
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
    |> Phoenix.Component.assign(
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
        |> Phoenix.Component.assign(studio_schedule: schedule, page_title: schedule.name)

      {:error, reason} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, action_error("load schedule", reason))
        |> Phoenix.LiveView.push_navigate(to: "/schedules")
    end
  end

  # --- Event Handlers ---

  # Agent events

  def handle_studio_event("save_agent", %{"agent" => params}, socket) do
    user_id = socket.assigns.current_user.id
    params = params |> decode_opinions()

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
         |> Phoenix.LiveView.put_flash(:info, msg)
         |> Phoenix.LiveView.push_navigate(to: "/agents/#{agent.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:error, format_changeset(changeset))
         |> Phoenix.Component.assign(agent_form: agent_form(params))}
    end
  end

  def handle_studio_event("validate_agent", %{"agent" => params}, socket) do
    params = normalize_opinion_params(params)
    {:noreply, Phoenix.Component.assign(socket, agent_form: agent_form(params))}
  end

  def handle_studio_event("select_strategy", %{"strategy" => strategy}, socket) do
    current = socket.assigns.agent_form.params

    {:noreply,
     Phoenix.Component.assign(socket, agent_form: agent_form(%{current | "strategy" => strategy}))}
  end

  def handle_studio_event("add_opinion", _params, socket) do
    current = socket.assigns.agent_form.params
    opinions = (current["opinions"] || []) ++ [%{"key" => "", "value" => ""}]

    {:noreply,
     Phoenix.Component.assign(socket, agent_form: agent_form(%{current | "opinions" => opinions}))}
  end

  def handle_studio_event("remove_opinion", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    current = socket.assigns.agent_form.params
    opinions = List.delete_at(current["opinions"] || [], idx)

    {:noreply,
     Phoenix.Component.assign(socket, agent_form: agent_form(%{current | "opinions" => opinions}))}
  end

  def handle_studio_event("confirm_delete_agent", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_agent_id: id)}
  end

  def handle_studio_event("cancel_delete_agent", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_agent_id: nil)}
  end

  def handle_studio_event("delete_agent", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Agents.delete_agent(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Agent deleted")
         |> Phoenix.LiveView.push_navigate(to: "/agents")}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("delete agent", reason))}
    end
  end

  def handle_studio_event("add_agent_tool", %{"server_id" => "builtin:" <> _ = id}, socket) do
    agent = socket.assigns.editing_agent
    existing = get_in(agent.config, ["builtin_server_ids"]) || []

    if id in existing do
      {:noreply, socket}
    else
      config = Map.put(agent.config || %{}, "builtin_server_ids", existing ++ [id])

      case Agents.update_agent(agent.id, socket.assigns.current_user.id, %{config: config}) do
        {:ok, agent} ->
          available = compute_available_servers(socket.assigns.current_user.id, agent)

          {:noreply,
           Phoenix.Component.assign(socket,
             editing_agent: agent,
             available_mcp_servers: available
           )}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, action_error("add server", reason))}
      end
    end
  end

  def handle_studio_event("add_agent_tool", %{"server_id" => server_id}, socket) do
    agent = socket.assigns.editing_agent

    case Agents.add_tool(agent.id, server_id, nil, socket.assigns.current_user.id) do
      {:ok, _tool} ->
        {:ok, agent} = Agents.get_agent(agent.id, socket.assigns.current_user.id)
        available = compute_available_servers(socket.assigns.current_user.id, agent)

        {:noreply,
         Phoenix.Component.assign(socket,
           editing_agent: agent,
           available_mcp_servers: available
         )}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, action_error("add server", reason))}
    end
  end

  def handle_studio_event("remove_agent_tool", %{"server_id" => "builtin:" <> _ = id}, socket) do
    agent = socket.assigns.editing_agent
    existing = get_in(agent.config, ["builtin_server_ids"]) || []
    config = Map.put(agent.config || %{}, "builtin_server_ids", List.delete(existing, id))

    case Agents.update_agent(agent.id, socket.assigns.current_user.id, %{config: config}) do
      {:ok, agent} ->
        available = compute_available_servers(socket.assigns.current_user.id, agent)

        {:noreply,
         Phoenix.Component.assign(socket,
           editing_agent: agent,
           available_mcp_servers: available
         )}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("remove server", reason))}
    end
  end

  def handle_studio_event("remove_agent_tool", %{"server_id" => server_id}, socket) do
    agent = socket.assigns.editing_agent

    case Agents.remove_tool(agent.id, server_id, nil, socket.assigns.current_user.id) do
      {:ok, _} ->
        {:ok, agent} = Agents.get_agent(agent.id, socket.assigns.current_user.id)
        available = compute_available_servers(socket.assigns.current_user.id, agent)

        {:noreply,
         Phoenix.Component.assign(socket,
           editing_agent: agent,
           available_mcp_servers: available
         )}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("remove server", reason))}
    end
  end

  # Team events

  def handle_studio_event("save_team", %{"team" => params}, socket) do
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
         |> Phoenix.LiveView.put_flash(:info, msg)
         |> Phoenix.LiveView.push_navigate(to: "/teams/#{team.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:error, format_changeset(changeset))
         |> Phoenix.Component.assign(team_form: team_form(params))}
    end
  end

  def handle_studio_event("confirm_delete_team", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_team_id: id)}
  end

  def handle_studio_event("cancel_delete_team", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_team_id: nil)}
  end

  def handle_studio_event("delete_team", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Teams.delete_team(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Team deleted")
         |> Phoenix.LiveView.push_navigate(to: "/teams")}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("delete team", reason))}
    end
  end

  def handle_studio_event("add_team_member", %{"agent_id" => agent_id}, socket) do
    team = socket.assigns.editing_team
    user_id = socket.assigns.current_user.id

    case Teams.add_member(team.id, agent_id, user_id) do
      {:ok, _member} ->
        {:ok, team} = Teams.get_team(team.id, socket.assigns.current_user.id)
        member_agent_ids = MapSet.new(team.team_members, & &1.agent_definition_id)

        available_agents =
          Enum.reject(socket.assigns.available_agents, &MapSet.member?(member_agent_ids, &1.id))

        {:noreply,
         Phoenix.Component.assign(socket,
           editing_team: team,
           available_agents: available_agents
         )}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("add team member", reason))}
    end
  end

  def handle_studio_event("remove_team_member", %{"agent_id" => agent_id}, socket) do
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
         Phoenix.Component.assign(socket,
           editing_team: team,
           available_agents: available_agents
         )}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("remove team member", reason))}
    end
  end

  # Run events

  def handle_studio_event("save_run", %{"run" => form_params}, socket) do
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
         |> Phoenix.LiveView.put_flash(:info, "Run created")
         |> Phoenix.LiveView.push_navigate(to: "/runs/#{run.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:error, format_changeset(changeset))
         |> Phoenix.Component.assign(run_form: run_form(form_params))}
    end
  end

  def handle_studio_event("start_run", _params, socket) do
    user_id = socket.assigns.current_user.id
    run = socket.assigns.studio_run

    if run.status != "pending" do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "Run can only be started when pending")}
    else
      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        Runner.run(run.id, user_id)
      end)

      {:noreply,
       socket
       |> Phoenix.LiveView.put_flash(:info, "Run started.")
       |> Phoenix.Component.assign(studio_run: %{run | status: "running"})}
    end
  end

  def handle_studio_event("rerun", %{"id" => id}, socket) do
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
       |> Phoenix.LiveView.put_flash(:info, "Rerun started.")
       |> Phoenix.LiveView.push_navigate(to: "/runs/#{new_run.id}")}
    else
      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, action_error("rerun", reason))}
    end
  end

  def handle_studio_event("retry_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.get_run(id, user_id) do
      {:ok, %{status: status} = run} when status in ["failed", "cancelled"] ->
        Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
          Runner.run(run.id, user_id)
        end)

        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Retrying run...")
         |> Phoenix.Component.assign(studio_run: %{run | status: "running"})}

      {:ok, _} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           "Only failed or cancelled runs can be retried"
         )}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, action_error("retry run", reason))}
    end
  end

  def handle_studio_event("cancel_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.cancel_run(id, user_id) do
      {:ok, run} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Run cancelled")
         |> Phoenix.Component.assign(studio_run: Runs.get_run!(run.id))}

      {:error, :not_running} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("cancel run", :not_running))}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, action_error("cancel run", reason))}
    end
  end

  def handle_studio_event("confirm_delete_run", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_run_id: id)}
  end

  def handle_studio_event("cancel_delete_run", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_run_id: nil)}
  end

  def handle_studio_event("delete_run", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Runs.delete_run(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Run deleted")
         |> Phoenix.LiveView.push_navigate(to: "/runs")}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, action_error("delete run", reason))}
    end
  end

  # Schedule events

  def handle_studio_event("save_schedule", %{"schedule" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.create_schedule(Map.put(params, "user_id", user_id)) do
      {:ok, schedule} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Schedule created")
         |> Phoenix.LiveView.push_navigate(to: "/schedules/#{schedule.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:error, format_changeset(changeset))
         |> Phoenix.Component.assign(schedule_form: schedule_form(params))}
    end
  end

  def handle_studio_event("toggle_schedule", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.toggle_schedule(id, user_id) do
      {:ok, _} ->
        schedules = Schedules.list_schedules(user_id)
        {:noreply, Phoenix.Component.assign(socket, studio_schedules: schedules)}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("toggle schedule", reason))}
    end
  end

  def handle_studio_event("confirm_delete_schedule", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_schedule_id: id)}
  end

  def handle_studio_event("cancel_delete_schedule", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_schedule_id: nil)}
  end

  def handle_studio_event("delete_schedule", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.delete_schedule(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Schedule deleted")
         |> Phoenix.LiveView.push_navigate(to: "/schedules")}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("delete schedule", reason))}
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
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.reduce(%{}, fn {_idx, %{"key" => k, "value" => v}}, acc ->
        key = String.trim(k)
        if key != "", do: Map.put(acc, key, String.trim(v)), else: acc
      end)

    Map.put(params, "opinions", opinions)
  end

  defp decode_opinions(params), do: params

  defp normalize_opinion_params(%{"opinions" => entries} = params) when is_map(entries) do
    opinions =
      entries
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
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

  defp parse_cost_limit_param(%{"cost_limit" => ""} = params),
    do: Map.delete(params, "cost_limit")

  defp parse_cost_limit_param(%{"cost_limit" => val} = params) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> %{params | "cost_limit" => d}
      _ -> Map.delete(params, "cost_limit")
    end
  end

  defp parse_cost_limit_param(params), do: params

  defp compute_available_servers(user_id, agent) do
    all_servers = McpServers.list_servers(user_id)
    assigned_db_ids = MapSet.new(agent.agent_tools, & &1.mcp_server_id)
    assigned_builtin_ids = MapSet.new(get_in(agent.config, ["builtin_server_ids"]) || [])

    Enum.reject(all_servers, fn server ->
      if Map.has_key?(server, :builtin) do
        MapSet.member?(assigned_builtin_ids, server.id)
      else
        MapSet.member?(assigned_db_ids, server.id)
      end
    end)
  end

  # --- Run PubSub ---

  def handle_run_info({:run_updated, run}, socket) do
    run_usage = Liteskill.Usage.usage_by_run(run.id)
    run_usage_by_model = Liteskill.Usage.usage_by_run_and_model(run.id)

    {:noreply,
     Phoenix.Component.assign(socket,
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
             Phoenix.Component.assign(socket,
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
end
