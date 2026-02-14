defmodule LiteskillWeb.AgentStudioLive do
  @moduledoc """
  Agent Studio event handlers and helpers, rendered within ChatLive's main area.
  Handles Agents, Teams, Instances, and Schedules pages.
  """

  use LiteskillWeb, :html

  alias Liteskill.Agents
  alias Liteskill.Instances
  alias Liteskill.Instances.Runner
  alias Liteskill.Schedules
  alias Liteskill.Teams

  @studio_actions [
    :agents,
    :agent_new,
    :agent_show,
    :agent_edit,
    :teams,
    :team_new,
    :team_show,
    :team_edit,
    :instances,
    :instance_new,
    :instance_show,
    :schedules,
    :schedule_new,
    :schedule_show
  ]

  def studio_action?(action), do: action in @studio_actions

  def studio_assigns do
    [
      studio_agents: [],
      studio_agent: nil,
      studio_teams: [],
      studio_team: nil,
      studio_instances: [],
      studio_instance: nil,
      studio_schedules: [],
      studio_schedule: nil,
      agent_form: agent_form(),
      team_form: team_form(),
      instance_form: instance_form(),
      schedule_form: schedule_form(),
      editing_agent: nil,
      editing_team: nil,
      confirm_delete_agent_id: nil,
      confirm_delete_team_id: nil,
      confirm_delete_instance_id: nil,
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
          "opinions" => "",
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

  def instance_form(data \\ %{}) do
    Phoenix.Component.to_form(
      Map.merge(
        %{
          "name" => "",
          "description" => "",
          "prompt" => "",
          "topology" => "pipeline",
          "team_definition_id" => "",
          "timeout_ms" => "1800000",
          "max_iterations" => "50"
        },
        data
      ),
      as: :instance
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

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Agent not found")
        |> Phoenix.LiveView.push_navigate(to: "/agents")
    end
  end

  def apply_studio_action(socket, :agent_edit, %{"agent_id" => agent_id}) do
    user_id = socket.assigns.current_user.id

    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        socket
        |> reset_common()
        |> Phoenix.Component.assign(
          editing_agent: agent,
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

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Agent not found")
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

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Team not found")
        |> Phoenix.LiveView.push_navigate(to: "/teams")
    end
  end

  def apply_studio_action(socket, :team_edit, %{"team_id" => team_id}) do
    user_id = socket.assigns.current_user.id

    case Teams.get_team(team_id, user_id) do
      {:ok, team} ->
        socket
        |> reset_common()
        |> Phoenix.Component.assign(
          editing_team: team,
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

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Team not found")
        |> Phoenix.LiveView.push_navigate(to: "/teams")
    end
  end

  # Instances

  def apply_studio_action(socket, :instances, _params) do
    user_id = socket.assigns.current_user.id
    instances = Instances.list_instances(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
      studio_instances: instances,
      confirm_delete_instance_id: nil,
      page_title: "Instances"
    )
  end

  def apply_studio_action(socket, :instance_new, _params) do
    user_id = socket.assigns.current_user.id
    teams = Teams.list_teams(user_id)

    socket
    |> reset_common()
    |> Phoenix.Component.assign(
      instance_form: instance_form(),
      studio_teams: teams,
      page_title: "New Instance"
    )
  end

  def apply_studio_action(socket, :instance_show, %{"instance_id" => instance_id}) do
    user_id = socket.assigns.current_user.id

    case Instances.get_instance(instance_id, user_id) do
      {:ok, instance} ->
        socket
        |> reset_common()
        |> Phoenix.Component.assign(studio_instance: instance, page_title: instance.name)

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Instance not found")
        |> Phoenix.LiveView.push_navigate(to: "/instances")
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

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Schedule not found")
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
         |> Phoenix.LiveView.put_flash(:error, format_errors(changeset))
         |> Phoenix.Component.assign(agent_form: agent_form(params))}
    end
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

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not delete agent")}
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
         |> Phoenix.LiveView.put_flash(:error, format_errors(changeset))
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

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not delete team")}
    end
  end

  # Instance events

  def handle_studio_event("save_instance", %{"instance" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case Instances.create_instance(Map.put(params, "user_id", user_id)) do
      {:ok, instance} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Instance created")
         |> Phoenix.LiveView.push_navigate(to: "/instances/#{instance.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:error, format_errors(changeset))
         |> Phoenix.Component.assign(instance_form: instance_form(params))}
    end
  end

  def handle_studio_event("run_instance", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
      Runner.run(id, user_id)
    end)

    {:noreply,
     socket
     |> Phoenix.LiveView.put_flash(:info, "Instance started. Refresh to see results.")
     |> Phoenix.Component.assign(
       studio_instance: %{socket.assigns.studio_instance | status: "running"}
     )}
  end

  def handle_studio_event("confirm_delete_instance", %{"id" => id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_instance_id: id)}
  end

  def handle_studio_event("cancel_delete_instance", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, confirm_delete_instance_id: nil)}
  end

  def handle_studio_event("delete_instance", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Instances.delete_instance(id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.LiveView.put_flash(:info, "Instance deleted")
         |> Phoenix.LiveView.push_navigate(to: "/instances")}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not delete instance")}
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
         |> Phoenix.LiveView.put_flash(:error, format_errors(changeset))
         |> Phoenix.Component.assign(schedule_form: schedule_form(params))}
    end
  end

  def handle_studio_event("toggle_schedule", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Schedules.toggle_schedule(id, user_id) do
      {:ok, _} ->
        schedules = Schedules.list_schedules(user_id)
        {:noreply, Phoenix.Component.assign(socket, studio_schedules: schedules)}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not toggle schedule")}
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

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not delete schedule")}
    end
  end

  # --- Helpers ---

  defp encode_opinions(nil), do: ""
  defp encode_opinions(map) when map == %{}, do: ""

  defp encode_opinions(map) when is_map(map) do
    Enum.map_join(map, "\n", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp decode_opinions(%{"opinions" => text} = params) when is_binary(text) do
    opinions =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
          _ -> acc
        end
      end)

    Map.put(params, "opinions", opinions)
  end

  defp decode_opinions(params), do: params

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end

  defp format_errors(_), do: "An error occurred"
end
