defmodule LiteskillWeb.AgentStudioComponents do
  @moduledoc """
  Components for the Agent Studio pages: Agents, Teams, Instances, Schedules.
  """

  use LiteskillWeb, :html

  alias Liteskill.Agents.AgentDefinition
  alias Liteskill.Teams.TeamDefinition
  alias Liteskill.Instances.Instance

  # ---- Full-Page Form Wrappers ----

  attr :form, :map, required: true
  attr :editing, :any, default: nil
  attr :available_models, :list, default: []
  attr :sidebar_open, :boolean, default: true

  def agent_form_page(assigns) do
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
        <.link navigate={~p"/agents"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          {if @editing, do: "Edit Agent", else: "New Agent"}
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_agent" class="space-y-6">
          <.agent_form_fields form={@form} editing={@editing} available_models={@available_models} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update Agent", else: "Create Agent"}
            </button>
            <.link navigate={~p"/agents"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :editing, :any, default: nil
  attr :sidebar_open, :boolean, default: true

  def team_form_page(assigns) do
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
        <.link navigate={~p"/teams"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          {if @editing, do: "Edit Team", else: "New Team"}
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_team" class="space-y-6">
          <.team_form_fields form={@form} editing={@editing} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update Team", else: "Create Team"}
            </button>
            <.link navigate={~p"/teams"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []
  attr :sidebar_open, :boolean, default: true

  def instance_form_page(assigns) do
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
        <.link navigate={~p"/instances"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          New Instance
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_instance" class="space-y-6">
          <.instance_form_fields form={@form} teams={@teams} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">Create Instance</button>
            <.link navigate={~p"/instances"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []
  attr :sidebar_open, :boolean, default: true

  def schedule_form_page(assigns) do
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
        <.link navigate={~p"/schedules"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          New Schedule
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_schedule" class="space-y-6">
          <.schedule_form_fields form={@form} teams={@teams} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">Create Schedule</button>
            <.link navigate={~p"/schedules"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ---- Agents ----

  attr :agents, :list, required: true
  attr :current_user, :map, required: true

  def agents_list(assigns) do
    ~H"""
    <div
      :if={@agents != []}
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
    >
      <.agent_card :for={agent <- @agents} agent={agent} owned={agent.user_id == @current_user.id} />
    </div>
    <p :if={@agents == []} class="text-base-content/50 text-center py-12">
      No agents yet. Create one to get started.
    </p>
    """
  end

  attr :agent, :map, required: true
  attr :owned, :boolean, default: false

  def agent_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md transition-shadow">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <.link
              navigate={~p"/agents/#{@agent.id}"}
              class="font-semibold text-base hover:text-primary transition-colors truncate block"
            >
              {@agent.name}
            </.link>
            <p :if={@agent.description} class="text-sm text-base-content/60 mt-1 line-clamp-2">
              {@agent.description}
            </p>
          </div>
          <div class="flex items-center gap-1 ml-2">
            <span class={[
              "badge badge-sm",
              if(@agent.status == "active", do: "badge-success", else: "badge-ghost")
            ]}>
              {@agent.status}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2 mt-3 text-xs text-base-content/50">
          <span class="badge badge-ghost badge-xs">{@agent.strategy}</span>
          <span :if={@agent.llm_model}>
            <.icon name="hero-cpu-chip-micro" class="size-3 inline" /> {@agent.llm_model.name}
          </span>
        </div>

        <div :if={@owned} class="flex items-center gap-1 mt-3 pt-3 border-t border-base-200">
          <.link navigate={~p"/agents/#{@agent.id}/edit"} class="btn btn-ghost btn-xs">
            <.icon name="hero-pencil-micro" class="size-3" /> Edit
          </.link>
          <button
            phx-click="open_sharing"
            phx-value-entity_type="agent_definition"
            phx-value-entity_id={@agent.id}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-share-micro" class="size-3" /> Share
          </button>
          <button
            phx-click="confirm_delete_agent"
            phx-value-id={@agent.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :editing, :any, default: nil
  attr :available_models, :list, default: []

  def agent_form_fields(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <label class="label"><span class="label-text font-medium">Name</span></label>
        <input
          type="text"
          name={@form[:name].name}
          value={@form[:name].value}
          class="input input-bordered w-full"
          placeholder="Research Assistant"
          required
        />
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Description</span></label>
        <textarea
          name={@form[:description].name}
          class="textarea textarea-bordered w-full h-20"
          placeholder="Brief description of this agent's purpose"
        >{@form[:description].value}</textarea>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Strategy</span></label>
          <select name={@form[:strategy].name} class="select select-bordered w-full">
            <option
              :for={s <- AgentDefinition.valid_strategies()}
              value={s}
              selected={@form[:strategy].value == s}
            >
              {strategy_label(s)}
            </option>
          </select>
        </div>

        <div>
          <label class="label"><span class="label-text font-medium">Model</span></label>
          <select name={@form[:llm_model_id].name} class="select select-bordered w-full">
            <option value="">No model selected</option>
            <option
              :for={model <- @available_models}
              value={model.id}
              selected={@form[:llm_model_id].value == model.id}
            >
              {model.name}
            </option>
          </select>
        </div>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Backstory</span></label>
        <textarea
          name={@form[:backstory].name}
          class="textarea textarea-bordered w-full h-32"
          placeholder="You are a thorough research assistant who always cites sources..."
        >{@form[:backstory].value}</textarea>
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            The agent's background and personality
          </span>
        </label>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">System Prompt</span></label>
        <textarea
          name={@form[:system_prompt].name}
          class="textarea textarea-bordered w-full h-32 font-mono text-sm"
          placeholder="You are a helpful AI assistant..."
        >{@form[:system_prompt].value}</textarea>
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            Direct instructions sent as the system message to the LLM
          </span>
        </label>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Opinions</span></label>
        <textarea
          name={@form[:opinions].name}
          class="textarea textarea-bordered w-full h-24 font-mono text-sm"
          placeholder="tone: professional\nformat: markdown\nverbosity: concise"
        >{@form[:opinions].value}</textarea>
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            Key-value pairs (one per line, key: value) that shape the agent's behavior
          </span>
        </label>
      </div>
    </div>
    """
  end

  defp strategy_label("react"), do: "ReAct (Reason + Act)"
  defp strategy_label("chain_of_thought"), do: "Chain of Thought"
  defp strategy_label("tree_of_thoughts"), do: "Tree of Thoughts"
  defp strategy_label("direct"), do: "Direct"
  defp strategy_label(s), do: s

  # ---- Teams ----

  attr :teams, :list, required: true
  attr :current_user, :map, required: true

  def teams_list(assigns) do
    ~H"""
    <div
      :if={@teams != []}
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
    >
      <.team_card :for={team <- @teams} team={team} owned={team.user_id == @current_user.id} />
    </div>
    <p :if={@teams == []} class="text-base-content/50 text-center py-12">
      No teams yet. Create agents first, then organize them into teams.
    </p>
    """
  end

  attr :team, :map, required: true
  attr :owned, :boolean, default: false

  def team_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md transition-shadow">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <.link
              navigate={~p"/teams/#{@team.id}"}
              class="font-semibold text-base hover:text-primary transition-colors truncate block"
            >
              {@team.name}
            </.link>
            <p :if={@team.description} class="text-sm text-base-content/60 mt-1 line-clamp-2">
              {@team.description}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2 mt-3 text-xs text-base-content/50">
          <span class="badge badge-ghost badge-xs">{@team.default_topology}</span>
          <span>
            <.icon name="hero-user-group-micro" class="size-3 inline" />
            {length(@team.team_members)} agent(s)
          </span>
        </div>

        <div :if={@team.team_members != []} class="mt-2">
          <div class="flex flex-wrap gap-1">
            <span
              :for={member <- @team.team_members}
              class="badge badge-outline badge-xs"
            >
              {member.agent_definition.name}
            </span>
          </div>
        </div>

        <div :if={@owned} class="flex items-center gap-1 mt-3 pt-3 border-t border-base-200">
          <.link navigate={~p"/teams/#{@team.id}/edit"} class="btn btn-ghost btn-xs">
            <.icon name="hero-pencil-micro" class="size-3" /> Edit
          </.link>
          <button
            phx-click="open_sharing"
            phx-value-entity_type="team_definition"
            phx-value-entity_id={@team.id}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-share-micro" class="size-3" /> Share
          </button>
          <button
            phx-click="confirm_delete_team"
            phx-value-id={@team.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :editing, :any, default: nil

  def team_form_fields(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <label class="label"><span class="label-text font-medium">Name</span></label>
        <input
          type="text"
          name={@form[:name].name}
          value={@form[:name].value}
          class="input input-bordered w-full"
          placeholder="Content Creation Team"
          required
        />
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Description</span></label>
        <textarea
          name={@form[:description].name}
          class="textarea textarea-bordered w-full h-20"
          placeholder="Team purpose and goals"
        >{@form[:description].value}</textarea>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Shared Context</span></label>
        <textarea
          name={@form[:shared_context].name}
          class="textarea textarea-bordered w-full h-32"
          placeholder="Context shared with all agents in this team..."
        >{@form[:shared_context].value}</textarea>
        <label class="label">
          <span class="label-text-alt text-base-content/50">
            Instructions and context available to every agent in the team
          </span>
        </label>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Topology</span></label>
          <select name={@form[:default_topology].name} class="select select-bordered w-full">
            <option
              :for={t <- TeamDefinition.valid_topologies()}
              value={t}
              selected={@form[:default_topology].value == t}
            >
              {topology_label(t)}
            </option>
          </select>
          <label class="label">
            <span class="label-text-alt text-base-content/50">
              How agents coordinate
            </span>
          </label>
        </div>

        <div>
          <label class="label"><span class="label-text font-medium">Aggregation</span></label>
          <select name={@form[:aggregation_strategy].name} class="select select-bordered w-full">
            <option
              :for={a <- TeamDefinition.valid_aggregations()}
              value={a}
              selected={@form[:aggregation_strategy].value == a}
            >
              {String.capitalize(a)}
            </option>
          </select>
          <label class="label">
            <span class="label-text-alt text-base-content/50">
              How results are combined
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  # ---- Instances ----

  attr :instances, :list, required: true
  attr :current_user, :map, required: true

  def instances_list(assigns) do
    ~H"""
    <div :if={@instances != []} class="space-y-3">
      <.instance_row
        :for={instance <- @instances}
        instance={instance}
        owned={instance.user_id == @current_user.id}
      />
    </div>
    <p :if={@instances == []} class="text-base-content/50 text-center py-12">
      No instances yet. Create one to run a task.
    </p>
    """
  end

  attr :instance, :map, required: true
  attr :owned, :boolean, default: false

  def instance_row(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 p-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3 flex-1 min-w-0">
          <span class={["badge badge-sm", status_badge(@instance.status)]}>
            {@instance.status}
          </span>
          <.link
            navigate={~p"/instances/#{@instance.id}"}
            class="font-medium hover:text-primary transition-colors truncate"
          >
            {@instance.name}
          </.link>
          <span :if={@instance.team_definition} class="text-xs text-base-content/50">
            {@instance.team_definition.name}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span class="badge badge-ghost badge-xs">{@instance.topology}</span>
          <span class="text-xs text-base-content/50">
            {Calendar.strftime(@instance.inserted_at, "%b %d, %H:%M")}
          </span>
          <button
            :if={@owned}
            phx-click="confirm_delete_instance"
            phx-value-id={@instance.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
      <p :if={@instance.description} class="text-sm text-base-content/60 mt-1 truncate">
        {@instance.description}
      </p>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []

  def instance_form_fields(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <label class="label"><span class="label-text font-medium">Name</span></label>
        <input
          type="text"
          name={@form[:name].name}
          value={@form[:name].value}
          class="input input-bordered w-full"
          placeholder="Write blog post about AI"
          required
        />
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Description</span></label>
        <textarea
          name={@form[:description].name}
          class="textarea textarea-bordered w-full h-20"
          placeholder="What this instance will accomplish"
        >{@form[:description].value}</textarea>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Prompt</span></label>
        <textarea
          name={@form[:prompt].name}
          class="textarea textarea-bordered w-full h-32"
          placeholder="The task to execute..."
          required
        >{@form[:prompt].value}</textarea>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Team</span></label>
          <select name={@form[:team_definition_id].name} class="select select-bordered w-full">
            <option value="">No team</option>
            <option
              :for={team <- @teams}
              value={team.id}
              selected={@form[:team_definition_id].value == team.id}
            >
              {team.name}
            </option>
          </select>
        </div>

        <div>
          <label class="label"><span class="label-text font-medium">Topology</span></label>
          <select name={@form[:topology].name} class="select select-bordered w-full">
            <option
              :for={t <- Instance.valid_topologies()}
              value={t}
              selected={@form[:topology].value == t}
            >
              {topology_label(t)}
            </option>
          </select>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Timeout (ms)</span></label>
          <input
            type="number"
            name={@form[:timeout_ms].name}
            value={@form[:timeout_ms].value}
            class="input input-bordered w-full"
            min="1000"
          />
        </div>
        <div>
          <label class="label"><span class="label-text font-medium">Max Iterations</span></label>
          <input
            type="number"
            name={@form[:max_iterations].name}
            value={@form[:max_iterations].value}
            class="input input-bordered w-full"
            min="1"
          />
        </div>
      </div>
    </div>
    """
  end

  # ---- Schedules ----

  attr :schedules, :list, required: true
  attr :current_user, :map, required: true

  def schedules_list(assigns) do
    ~H"""
    <div :if={@schedules != []} class="space-y-3">
      <.schedule_row
        :for={schedule <- @schedules}
        schedule={schedule}
        owned={schedule.user_id == @current_user.id}
      />
    </div>
    <p :if={@schedules == []} class="text-base-content/50 text-center py-12">
      No schedules yet. Create one to run instances on a recurring basis.
    </p>
    """
  end

  attr :schedule, :map, required: true
  attr :owned, :boolean, default: false

  def schedule_row(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 p-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3 flex-1 min-w-0">
          <input
            :if={@owned}
            type="checkbox"
            class="toggle toggle-sm toggle-primary"
            checked={@schedule.enabled}
            phx-click="toggle_schedule"
            phx-value-id={@schedule.id}
          />
          <span
            :if={!@owned}
            class={[
              "badge badge-sm",
              if(@schedule.enabled, do: "badge-success", else: "badge-ghost")
            ]}
          >
            {if @schedule.enabled, do: "enabled", else: "disabled"}
          </span>
          <.link
            navigate={~p"/schedules/#{@schedule.id}"}
            class="font-medium hover:text-primary transition-colors truncate"
          >
            {@schedule.name}
          </.link>
        </div>
        <div class="flex items-center gap-2">
          <code class="text-xs bg-base-200 px-2 py-0.5 rounded">{@schedule.cron_expression}</code>
          <span class="text-xs text-base-content/50">{@schedule.timezone}</span>
          <button
            :if={@owned}
            phx-click="confirm_delete_schedule"
            phx-value-id={@schedule.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
      <p :if={@schedule.description} class="text-sm text-base-content/60 mt-1 truncate">
        {@schedule.description}
      </p>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []

  def schedule_form_fields(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <label class="label"><span class="label-text font-medium">Name</span></label>
        <input
          type="text"
          name={@form[:name].name}
          value={@form[:name].value}
          class="input input-bordered w-full"
          placeholder="Daily report generation"
          required
        />
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Description</span></label>
        <textarea
          name={@form[:description].name}
          class="textarea textarea-bordered w-full h-20"
          placeholder="What this schedule does"
        >{@form[:description].value}</textarea>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Cron Expression</span></label>
          <input
            type="text"
            name={@form[:cron_expression].name}
            value={@form[:cron_expression].value}
            class="input input-bordered w-full font-mono"
            placeholder="0 9 * * *"
            required
          />
          <label class="label">
            <span class="label-text-alt text-base-content/50">min hour day month weekday</span>
          </label>
        </div>

        <div>
          <label class="label"><span class="label-text font-medium">Timezone</span></label>
          <input
            type="text"
            name={@form[:timezone].name}
            value={@form[:timezone].value}
            class="input input-bordered w-full"
            placeholder="UTC"
          />
        </div>
      </div>

      <div>
        <label class="label"><span class="label-text font-medium">Prompt</span></label>
        <textarea
          name={@form[:prompt].name}
          class="textarea textarea-bordered w-full h-32"
          placeholder="The task to run on each schedule..."
          required
        >{@form[:prompt].value}</textarea>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="label"><span class="label-text font-medium">Team</span></label>
          <select name={@form[:team_definition_id].name} class="select select-bordered w-full">
            <option value="">No team</option>
            <option
              :for={team <- @teams}
              value={team.id}
              selected={@form[:team_definition_id].value == team.id}
            >
              {team.name}
            </option>
          </select>
        </div>

        <div>
          <label class="label"><span class="label-text font-medium">Topology</span></label>
          <select name={@form[:topology].name} class="select select-bordered w-full">
            <option
              :for={t <- Instance.valid_topologies()}
              value={t}
              selected={@form[:topology].value == t}
            >
              {topology_label(t)}
            </option>
          </select>
        </div>
      </div>
    </div>
    """
  end

  # ---- Shared Helpers ----

  defp topology_label("pipeline"), do: "Pipeline (Serial)"
  defp topology_label("parallel"), do: "Parallel (Fan-out)"
  defp topology_label("debate"), do: "Debate"
  defp topology_label("hierarchical"), do: "Hierarchical"
  defp topology_label("round_robin"), do: "Round Robin"
  defp topology_label(t), do: t

  defp status_badge("pending"), do: "badge-ghost"
  defp status_badge("running"), do: "badge-info"
  defp status_badge("completed"), do: "badge-success"
  defp status_badge("failed"), do: "badge-error"
  defp status_badge("cancelled"), do: "badge-warning"
  defp status_badge(_), do: "badge-ghost"
end
