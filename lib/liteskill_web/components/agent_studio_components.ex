defmodule LiteskillWeb.AgentStudioComponents do
  @moduledoc """
  Components for the Agent Studio pages: Agents, Teams, Runs, Schedules.
  """

  use LiteskillWeb, :html

  import LiteskillWeb.FormatHelpers, only: [format_cost: 1, format_number: 1]

  alias Liteskill.Agents.AgentDefinition
  alias Liteskill.Teams.TeamDefinition
  alias Liteskill.Runs.Run
  alias LiteskillWeb.ChatComponents

  # ---- Full-Page Form Wrappers ----

  attr :form, :map, required: true
  attr :editing, :any, default: nil
  attr :available_models, :list, default: []
  attr :available_mcp_servers, :list, default: []
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
        <.link navigate={~p"/agents/list"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          {if @editing, do: "Edit Agent", else: "New Agent"}
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_agent" phx-change="validate_agent" class="space-y-6">
          <.agent_form_fields form={@form} editing={@editing} available_models={@available_models} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update Agent", else: "Create Agent"}
            </button>
            <.link navigate={~p"/agents/list"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
        <.agent_tools_section
          :if={@editing}
          agent={@editing}
          available_mcp_servers={@available_mcp_servers}
        />
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :editing, :any, default: nil
  attr :available_agents, :list, default: []
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
        <.team_members_section
          :if={@editing}
          team={@editing}
          available_agents={@available_agents}
        />
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []
  attr :sidebar_open, :boolean, default: true

  def run_form_page(assigns) do
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
        <.link navigate={~p"/runs"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          New Run
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl">
        <.form for={@form} phx-submit="save_run" class="space-y-6">
          <.run_form_fields form={@form} teams={@teams} />
          <div class="flex items-center gap-3 pt-4 border-t border-base-200">
            <button type="submit" class="btn btn-primary">Create Run</button>
            <.link navigate={~p"/runs"} class="btn btn-ghost">Cancel</.link>
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
          <input type="hidden" name={@form[:strategy].name} value={@form[:strategy].value} />
          <button
            type="button"
            onclick="document.getElementById('strategy-modal').showModal()"
            class="btn btn-outline w-full justify-between font-normal"
          >
            {strategy_label(@form[:strategy].value)}
            <.icon name="hero-chevron-down-micro" class="size-4 opacity-50" />
          </button>
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

      <dialog id="strategy-modal" class="modal">
        <div class="modal-box max-w-2xl">
          <h3 class="text-lg font-bold mb-4">Choose a Strategy</h3>
          <div class="grid grid-cols-1 gap-3">
            <.strategy_card
              :for={s <- AgentDefinition.valid_strategies()}
              strategy={s}
              selected={@form[:strategy].value == s}
            />
          </div>
          <div class="modal-action">
            <form method="dialog">
              <button class="btn btn-sm">Cancel</button>
            </form>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>close</button>
        </form>
      </dialog>

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
        <p class="text-sm text-base-content/50 mb-3">
          Steer the agent's style and defaults. e.g. <span class="font-mono">tone</span>
          &rarr; <span class="font-mono">concise and direct</span>,
          <span class="font-mono">format</span>
          &rarr; <span class="font-mono">markdown with headers</span>
        </p>
        <div class="space-y-2">
          <div
            :for={{entry, idx} <- Enum.with_index(@form[:opinions].value || [])}
            class="flex items-center gap-2"
          >
            <input
              type="text"
              name={"#{@form[:opinions].name}[#{idx}][key]"}
              value={entry["key"]}
              class="input input-bordered input-sm flex-1 font-mono"
              placeholder="key"
            />
            <input
              type="text"
              name={"#{@form[:opinions].name}[#{idx}][value]"}
              value={entry["value"]}
              class="input input-bordered input-sm flex-1 font-mono"
              placeholder="value"
            />
            <button
              type="button"
              phx-click="remove_opinion"
              phx-value-index={idx}
              class="btn btn-ghost btn-sm btn-circle text-error"
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>
        </div>
        <button type="button" phx-click="add_opinion" class="btn btn-ghost btn-sm mt-2 gap-1">
          <.icon name="hero-plus-micro" class="size-4" /> Add opinion
        </button>
      </div>
    </div>
    """
  end

  attr :strategy, :string, required: true
  attr :selected, :boolean, default: false

  defp strategy_card(assigns) do
    {label, desc} = strategy_info(assigns.strategy)
    assigns = assign(assigns, label: label, desc: desc)

    ~H"""
    <button
      type="button"
      phx-click="select_strategy"
      phx-value-strategy={@strategy}
      onclick="document.getElementById('strategy-modal').close()"
      class={"card card-bordered cursor-pointer transition-all hover:border-primary p-4 text-left #{if @selected, do: "border-primary bg-primary/5 ring-1 ring-primary", else: "border-base-300"}"}
    >
      <div class="flex items-center gap-2 mb-1">
        <span class="font-semibold">{@label}</span>
        <span :if={@selected} class="badge badge-primary badge-sm">Selected</span>
      </div>
      <p class="text-sm text-base-content/60">{@desc}</p>
    </button>
    """
  end

  defp strategy_info("react") do
    {"ReAct (Reason + Act)",
     "Thinks step-by-step, then acts. The agent reasons about what to do, uses a tool, observes the result, and repeats. Best for tasks that need multiple tool calls with decisions between each."}
  end

  defp strategy_info("chain_of_thought") do
    {"Chain of Thought",
     "Reasons through the full problem before responding. Produces a detailed internal monologue, then gives a single answer. Best for complex analysis where getting the logic right matters more than using tools."}
  end

  defp strategy_info("tree_of_thoughts") do
    {"Tree of Thoughts",
     "Explores multiple reasoning paths and picks the best one. Generates several candidate approaches, evaluates each, then commits. Best for open-ended problems with many valid solutions."}
  end

  defp strategy_info("direct") do
    {"Direct",
     "Responds immediately with no explicit reasoning steps. The agent gets the prompt and replies in one shot. Best for simple, well-defined tasks where extra deliberation adds no value."}
  end

  defp strategy_label(s) do
    {label, _} = strategy_info(s)
    label
  rescue
    _ -> s
  end

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

  attr :agent, :map, required: true
  attr :available_mcp_servers, :list, default: []

  def agent_tools_section(assigns) do
    builtin_ids = get_in(assigns.agent.config, ["builtin_server_ids"]) || []

    builtin_servers =
      Liteskill.BuiltinTools.virtual_servers()
      |> Enum.filter(&(&1.id in builtin_ids))

    assigns =
      assign(assigns, :assigned_servers, build_assigned_servers(assigns.agent, builtin_servers))

    ~H"""
    <div class="mt-8 pt-6 border-t border-base-200">
      <h2 class="text-lg font-semibold mb-4">MCP Servers</h2>

      <div :if={@assigned_servers != []} class="space-y-2 mb-4">
        <div
          :for={server <- @assigned_servers}
          class="flex items-center justify-between bg-base-200 rounded-lg p-3"
        >
          <div class="flex items-center gap-3">
            <.icon name="hero-server-micro" class="size-4 text-base-content/50" />
            <span class="font-medium">{server.name}</span>
            <span :if={server.builtin} class="badge badge-ghost badge-xs">builtin</span>
            <span
              :if={server.description}
              class="text-xs text-base-content/50 truncate max-w-xs"
            >
              {server.description}
            </span>
          </div>
          <button
            type="button"
            phx-click="remove_agent_tool"
            phx-value-server_id={server.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
      </div>

      <p :if={@assigned_servers == []} class="text-sm text-base-content/50 mb-4">
        No MCP servers assigned. Add servers below to give this agent access to tools.
      </p>

      <form
        :if={@available_mcp_servers != []}
        phx-submit="add_agent_tool"
        class="flex items-end gap-2"
      >
        <div class="flex-1">
          <label class="label"><span class="label-text font-medium">Add Server</span></label>
          <select name="server_id" class="select select-bordered w-full" required>
            <option value="">Select a server...</option>
            <option :for={server <- @available_mcp_servers} value={server.id}>
              {server.name}{if Map.has_key?(server, :builtin), do: " (builtin)", else: ""}
            </option>
          </select>
        </div>
        <button type="submit" class="btn btn-primary">
          <.icon name="hero-plus-micro" class="size-4" /> Add
        </button>
      </form>

      <p
        :if={@available_mcp_servers == [] && @assigned_servers != []}
        class="text-sm text-base-content/50"
      >
        All available servers are already assigned to this agent.
      </p>
    </div>
    """
  end

  attr :team, :map, required: true
  attr :available_agents, :list, default: []

  def team_members_section(assigns) do
    ~H"""
    <div class="mt-8 pt-6 border-t border-base-200">
      <h2 class="text-lg font-semibold mb-4">Agent Roster</h2>

      <div :if={@team.team_members != []} class="space-y-2 mb-4">
        <div
          :for={member <- @team.team_members}
          class="flex items-center justify-between bg-base-200 rounded-lg p-3"
        >
          <div class="flex items-center gap-3">
            <span class="badge badge-ghost badge-sm w-6 text-center font-mono">
              {member.position + 1}
            </span>
            <span class="font-medium">{member.agent_definition.name}</span>
            <span class="badge badge-outline badge-xs">{member.role}</span>
            <span
              :if={member.agent_definition.strategy}
              class="badge badge-ghost badge-xs"
            >
              {member.agent_definition.strategy}
            </span>
          </div>
          <button
            type="button"
            phx-click="remove_team_member"
            phx-value-agent_id={member.agent_definition_id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
      </div>

      <p :if={@team.team_members == []} class="text-sm text-base-content/50 mb-4">
        No agents in this team yet. Add agents below.
      </p>

      <form :if={@available_agents != []} phx-submit="add_team_member" class="flex items-end gap-2">
        <div class="flex-1">
          <label class="label"><span class="label-text font-medium">Add Agent</span></label>
          <select name="agent_id" class="select select-bordered w-full" required>
            <option value="">Select an agent...</option>
            <option :for={agent <- @available_agents} value={agent.id}>
              {agent.name}{if agent.strategy, do: " (#{agent.strategy})", else: ""}
            </option>
          </select>
        </div>
        <button type="submit" class="btn btn-primary">
          <.icon name="hero-plus-micro" class="size-4" /> Add
        </button>
      </form>

      <p
        :if={@available_agents == [] && @team.team_members != []}
        class="text-sm text-base-content/50"
      >
        All available agents are already in this team.
      </p>
    </div>
    """
  end

  # ---- Runs ----

  attr :runs, :list, required: true
  attr :current_user, :map, required: true

  def runs_list(assigns) do
    ~H"""
    <div :if={@runs != []} class="space-y-3">
      <.run_row
        :for={run <- @runs}
        run={run}
        owned={run.user_id == @current_user.id}
      />
    </div>
    <p :if={@runs == []} class="text-base-content/50 text-center py-12">
      No runs yet. Create one to run a task.
    </p>
    """
  end

  attr :run, :map, required: true
  attr :owned, :boolean, default: false

  def run_row(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 p-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3 flex-1 min-w-0">
          <span class={["badge badge-sm", status_badge(@run.status)]}>
            {@run.status}
          </span>
          <.link
            navigate={~p"/runs/#{@run.id}"}
            class="font-medium hover:text-primary transition-colors truncate"
          >
            {@run.name}
          </.link>
          <span :if={@run.team_definition} class="text-xs text-base-content/50">
            {@run.team_definition.name}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span class="badge badge-ghost badge-xs">{@run.topology}</span>
          <span class="text-xs text-base-content/50">
            {Calendar.strftime(@run.inserted_at, "%b %d, %H:%M")}
          </span>
          <button
            :if={@owned}
            phx-click="confirm_delete_run"
            phx-value-id={@run.id}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-3" />
          </button>
        </div>
      </div>
      <p :if={@run.description} class="text-sm text-base-content/60 mt-1 truncate">
        {@run.description}
      </p>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :teams, :list, default: []

  def run_form_fields(assigns) do
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
          placeholder="What this run will accomplish"
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
              :for={t <- Run.valid_topologies()}
              value={t}
              selected={@form[:topology].value == t}
            >
              {topology_label(t)}
            </option>
          </select>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-4">
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
        <div>
          <label class="label"><span class="label-text font-medium">Cost Limit ($)</span></label>
          <input
            type="number"
            name={@form[:cost_limit].name}
            value={@form[:cost_limit].value}
            class="input input-bordered w-full"
            step="0.10"
            min="0"
            placeholder="1.00"
          />
          <label class="label">
            <span class="label-text-alt text-base-content/50">
              Leave empty for no limit
            </span>
          </label>
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
      No schedules yet. Create one to execute runs on a recurring basis.
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
              :for={t <- Run.valid_topologies()}
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

  # ---- Agent Studio Landing Page ----

  attr :sidebar_open, :boolean, default: true

  def agent_studio_landing(assigns) do
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
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          Agent Studio
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl mx-auto grid grid-cols-1 sm:grid-cols-2 gap-6">
        <.link
          navigate={~p"/agents/list"}
          class="card bg-base-200 shadow-sm hover:shadow-md hover:bg-base-300 transition-all cursor-pointer"
        >
          <div class="card-body">
            <div class="flex items-center gap-3 mb-2">
              <.icon name="hero-cpu-chip" class="size-8 text-primary" />
              <h2 class="card-title text-lg">Agents</h2>
            </div>
            <p class="text-sm text-base-content/70">
              Create and configure individual AI agents with custom backstories,
              reasoning strategies, system prompts, and MCP tool integrations.
              Each agent can be tailored for specific tasks and workflows.
            </p>
          </div>
        </.link>

        <.link
          navigate={~p"/teams"}
          class="card bg-base-200 shadow-sm hover:shadow-md hover:bg-base-300 transition-all cursor-pointer"
        >
          <div class="card-body">
            <div class="flex items-center gap-3 mb-2">
              <.icon name="hero-user-group" class="size-8 text-primary" />
              <h2 class="card-title text-lg">Teams</h2>
            </div>
            <p class="text-sm text-base-content/70">
              Assemble agents into teams with different collaboration topologies
              like pipeline, parallel, debate, or hierarchical execution. Define
              how agents work together and aggregate their outputs.
            </p>
          </div>
        </.link>

        <.link
          navigate={~p"/runs"}
          class="card bg-base-200 shadow-sm hover:shadow-md hover:bg-base-300 transition-all cursor-pointer"
        >
          <div class="card-body">
            <div class="flex items-center gap-3 mb-2">
              <.icon name="hero-play-circle" class="size-8 text-primary" />
              <h2 class="card-title text-lg">Runs</h2>
            </div>
            <p class="text-sm text-base-content/70">
              Execute team workflows by providing a prompt and watching agents
              collaborate in real time. Track execution logs, token usage, costs,
              and view the final deliverables produced by each run.
            </p>
          </div>
        </.link>

        <.link
          navigate={~p"/schedules"}
          class="card bg-base-200 shadow-sm hover:shadow-md hover:bg-base-300 transition-all cursor-pointer"
        >
          <div class="card-body">
            <div class="flex items-center gap-3 mb-2">
              <.icon name="hero-clock" class="size-8 text-primary" />
              <h2 class="card-title text-lg">Schedules</h2>
            </div>
            <p class="text-sm text-base-content/70">
              Automate team runs on a recurring basis using cron expressions.
              Set up scheduled workflows with custom prompts and timezones,
              and toggle them on or off as needed.
            </p>
          </div>
        </.link>
      </div>
    </div>
    """
  end

  # ---- Full-Page Views (extracted from ChatLive) ----

  attr :agents, :list, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, default: true
  attr :confirm_delete_agent_id, :any, default: nil

  def agents_page(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            :if={!@sidebar_open}
            phx-click="toggle_sidebar"
            class="btn btn-circle btn-ghost btn-sm"
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
            Agents
          </h1>
        </div>
        <.link navigate={~p"/agents/new"} class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-plus-micro" class="size-4" /> New Agent
        </.link>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-4">
      <.agents_list agents={@agents} current_user={@current_user} />
    </div>
    <ChatComponents.confirm_modal
      :if={@confirm_delete_agent_id}
      show={@confirm_delete_agent_id != nil}
      title="Delete Agent"
      message="Are you sure you want to delete this agent? This cannot be undone."
      confirm_event={"delete_agent|#{@confirm_delete_agent_id}"}
      cancel_event="cancel_delete_agent"
    />
    """
  end

  attr :agent, :map, required: true
  attr :sidebar_open, :boolean, default: true

  def agent_show_page(assigns) do
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
        <.link navigate={~p"/agents/list"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          {@agent.name}
        </h1>
        <span class={[
          "badge badge-sm",
          if(@agent.status == "active", do: "badge-success", else: "badge-ghost")
        ]}>
          {@agent.status}
        </span>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl space-y-6">
        <div :if={@agent.description} class="prose">
          <p class="text-base-content/70">{@agent.description}</p>
        </div>
        <div class="grid grid-cols-2 gap-4">
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Strategy</h3>
            <p>{@agent.strategy}</p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Model</h3>
            <p>{if @agent.llm_model, do: @agent.llm_model.name, else: "None"}</p>
          </div>
        </div>
        <div :if={@agent.backstory}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Backstory</h3>
          <div class="bg-base-200 rounded-lg p-4 text-sm whitespace-pre-wrap">
            {@agent.backstory}
          </div>
        </div>
        <div :if={@agent.opinions != %{}}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Opinions</h3>
          <div class="bg-base-200 rounded-lg p-4">
            <div :for={{key, value} <- @agent.opinions} class="flex gap-2 text-sm mb-1">
              <span class="font-medium">{key}:</span>
              <span class="text-base-content/70">{value}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :teams, :list, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, default: true
  attr :confirm_delete_team_id, :any, default: nil

  def teams_page(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            :if={!@sidebar_open}
            phx-click="toggle_sidebar"
            class="btn btn-circle btn-ghost btn-sm"
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
            Teams
          </h1>
        </div>
        <.link navigate={~p"/teams/new"} class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-plus-micro" class="size-4" /> New Team
        </.link>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-4">
      <.teams_list teams={@teams} current_user={@current_user} />
    </div>
    <ChatComponents.confirm_modal
      :if={@confirm_delete_team_id}
      show={@confirm_delete_team_id != nil}
      title="Delete Team"
      message="Are you sure you want to delete this team? This cannot be undone."
      confirm_event={"delete_team|#{@confirm_delete_team_id}"}
      cancel_event="cancel_delete_team"
    />
    """
  end

  attr :team, :map, required: true
  attr :sidebar_open, :boolean, default: true

  def team_show_page(assigns) do
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
          {@team.name}
        </h1>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl space-y-6">
        <div :if={@team.description} class="prose">
          <p class="text-base-content/70">{@team.description}</p>
        </div>
        <div class="grid grid-cols-2 gap-4">
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Topology</h3>
            <p>{@team.default_topology}</p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Aggregation</h3>
            <p>{@team.aggregation_strategy}</p>
          </div>
        </div>
        <div :if={@team.shared_context}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Shared Context</h3>
          <div class="bg-base-200 rounded-lg p-4 text-sm whitespace-pre-wrap">
            {@team.shared_context}
          </div>
        </div>
        <div>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">
            Agent Roster ({length(@team.team_members)})
          </h3>
          <div :if={@team.team_members != []} class="space-y-2">
            <div
              :for={member <- @team.team_members}
              class="bg-base-200 rounded-lg p-3 flex items-center justify-between"
            >
              <div class="flex items-center gap-3">
                <span class="badge badge-ghost badge-sm w-6 text-center">
                  {member.position + 1}
                </span>
                <.link
                  navigate={~p"/agents/#{member.agent_definition.id}"}
                  class="font-medium hover:text-primary"
                >
                  {member.agent_definition.name}
                </.link>
                <span class="badge badge-outline badge-xs">{member.role}</span>
              </div>
            </div>
          </div>
          <p :if={@team.team_members == []} class="text-sm text-base-content/50">
            No agents in this team yet.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :runs, :list, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, default: true
  attr :confirm_delete_run_id, :any, default: nil

  def runs_page(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            :if={!@sidebar_open}
            phx-click="toggle_sidebar"
            class="btn btn-circle btn-ghost btn-sm"
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
            Runs
          </h1>
        </div>
        <.link navigate={~p"/runs/new"} class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-plus-micro" class="size-4" /> New Run
        </.link>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-4">
      <.runs_list runs={@runs} current_user={@current_user} />
    </div>
    <ChatComponents.confirm_modal
      :if={@confirm_delete_run_id}
      show={@confirm_delete_run_id != nil}
      title="Delete Run"
      message="Are you sure you want to delete this run?"
      confirm_event={"delete_run|#{@confirm_delete_run_id}"}
      cancel_event="cancel_delete_run"
    />
    """
  end

  attr :run, :map, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, default: true
  attr :run_usage, :map, default: nil
  attr :run_usage_by_model, :list, default: []

  def run_show_page(assigns) do
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
        <.link navigate={~p"/runs"} class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left-micro" class="size-4" />
        </.link>
        <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
          {@run.name}
        </h1>
        <span class={["badge badge-sm", status_badge(@run.status)]}>
          {@run.status}
        </span>
        <button
          :if={@run.status == "pending" && @run.user_id == @current_user.id}
          phx-click="start_run"
          phx-value-id={@run.id}
          class="btn btn-primary btn-sm ml-auto"
        >
          <.icon name="hero-play-micro" class="size-4" /> Run
        </button>
        <button
          :if={@run.status == "running" && @run.user_id == @current_user.id}
          phx-click="cancel_run"
          phx-value-id={@run.id}
          class="btn btn-warning btn-sm ml-auto"
          data-confirm="Cancel this run?"
        >
          <.icon name="hero-stop-micro" class="size-4" /> Cancel
        </button>
        <div
          :if={
            @run.status in ["failed", "cancelled"] &&
              @run.user_id == @current_user.id
          }
          class="flex gap-2 ml-auto"
        >
          <button
            phx-click="retry_run"
            phx-value-id={@run.id}
            phx-disable-with="Retrying…"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-arrow-path-micro" class="size-4" /> Retry
          </button>
          <button
            phx-click="rerun"
            phx-value-id={@run.id}
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-document-duplicate-micro" class="size-4" /> New Run
          </button>
        </div>
        <button
          :if={
            @run.status == "completed" &&
              @run.user_id == @current_user.id
          }
          phx-click="rerun"
          phx-value-id={@run.id}
          class="btn btn-outline btn-sm ml-auto"
        >
          <.icon name="hero-arrow-path-micro" class="size-4" /> Rerun
        </button>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl space-y-6">
        <div class="bg-base-200 rounded-lg p-4">
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Prompt</h3>
          <p class="text-sm whitespace-pre-wrap">{@run.prompt}</p>
        </div>
        <div class="grid grid-cols-4 gap-4">
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Topology</h3>
            <p>{@run.topology}</p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Team</h3>
            <p>
              {if @run.team_definition,
                do: @run.team_definition.name,
                else: "None"}
            </p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Status</h3>
            <p>{@run.status}</p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Duration</h3>
            <p
              id={"run-timer-#{@run.id}"}
              phx-hook="RunTimer"
              data-status={@run.status}
              data-started-at={
                @run.started_at && Calendar.strftime(@run.started_at, "%Y-%m-%dT%H:%M:%S")
              }
              data-completed-at={
                @run.completed_at && Calendar.strftime(@run.completed_at, "%Y-%m-%dT%H:%M:%S")
              }
            >
              {format_duration(@run.started_at, @run.completed_at)}
            </p>
          </div>
        </div>
        <div
          :if={@run.status == "failed" && @run.error}
          class="bg-error/10 border border-error/30 rounded-lg p-4"
        >
          <h3 class="text-sm font-semibold text-error mb-1">Error</h3>
          <p class="text-sm font-mono whitespace-pre-wrap">{@run.error}</p>
        </div>
        <div :if={@run.run_tasks != []}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">
            Tasks ({length(@run.run_tasks)})
          </h3>
          <div class="space-y-2">
            <div
              :for={task <- @run.run_tasks}
              class="bg-base-200 rounded-lg p-3 flex items-center justify-between"
            >
              <div class="flex items-center gap-2">
                <span class="badge badge-ghost badge-xs">{task.status}</span>
                <span class="font-medium text-sm">{task.name}</span>
              </div>
              <span :if={task.duration_ms} class="text-xs text-base-content/50">
                {task.duration_ms}ms
              </span>
            </div>
          </div>
        </div>
        <div :if={@run_usage && @run_usage.call_count > 0}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Usage & Cost</h3>
          <div class="grid grid-cols-3 gap-4 mb-4">
            <div class="bg-base-200 rounded-lg p-4 text-center">
              <p class="text-xs text-base-content/50 mb-1">Input Cost</p>
              <p class="text-lg font-bold">{format_cost(@run_usage.input_cost)}</p>
            </div>
            <div class="bg-base-200 rounded-lg p-4 text-center">
              <p class="text-xs text-base-content/50 mb-1">Output Cost</p>
              <p class="text-lg font-bold">{format_cost(@run_usage.output_cost)}</p>
            </div>
            <div class="bg-base-200 rounded-lg p-4 text-center">
              <p class="text-xs text-base-content/50 mb-1">Total Cost</p>
              <p class="text-lg font-bold text-primary">{format_cost(@run_usage.total_cost)}</p>
            </div>
          </div>
          <div class="bg-base-200 rounded-lg p-4 mb-4">
            <div class="grid grid-cols-4 gap-4 text-center text-sm">
              <div>
                <p class="text-xs text-base-content/50">Input Tokens</p>
                <p class="font-semibold">{format_number(@run_usage.input_tokens)}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/50">Output Tokens</p>
                <p class="font-semibold">{format_number(@run_usage.output_tokens)}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/50">Total Tokens</p>
                <p class="font-semibold">{format_number(@run_usage.total_tokens)}</p>
              </div>
              <div>
                <p class="text-xs text-base-content/50">API Calls</p>
                <p class="font-semibold">{@run_usage.call_count}</p>
              </div>
            </div>
          </div>
          <div :if={@run_usage_by_model != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Model</th>
                  <th class="text-right">Input</th>
                  <th class="text-right">Output</th>
                  <th class="text-right">Total Tokens</th>
                  <th class="text-right">In Cost</th>
                  <th class="text-right">Out Cost</th>
                  <th class="text-right">Total Cost</th>
                  <th class="text-right">Calls</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @run_usage_by_model}>
                  <td class="font-mono text-xs">{row.model_id}</td>
                  <td class="text-right">{format_number(row.input_tokens)}</td>
                  <td class="text-right">{format_number(row.output_tokens)}</td>
                  <td class="text-right">{format_number(row.total_tokens)}</td>
                  <td class="text-right">{format_cost(row.input_cost)}</td>
                  <td class="text-right">{format_cost(row.output_cost)}</td>
                  <td class="text-right font-semibold">{format_cost(row.total_cost)}</td>
                  <td class="text-right">{row.call_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        <div :if={@run.deliverables["report_id"]}>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Deliverables</h3>
          <div class="bg-base-200 rounded-lg p-4">
            <.link
              navigate={~p"/reports/#{@run.deliverables["report_id"]}"}
              class="btn btn-sm btn-primary gap-2"
            >
              <.icon name="hero-document-text-micro" class="size-4" /> View Report
            </.link>
          </div>
        </div>
        <div :if={@run.run_logs != []}>
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm font-semibold text-base-content/60">
              Execution Log ({length(@run.run_logs)})
            </h3>
          </div>
          <div class="bg-base-300 rounded-lg overflow-hidden font-mono text-xs">
            <.link
              :for={entry <- @run.run_logs}
              navigate={~p"/runs/#{@run.id}/logs/#{entry.id}"}
              class="block border-b border-base-content/5 last:border-0 px-3 py-2 hover:bg-base-content/10 cursor-pointer transition-colors"
            >
              <div class="flex items-start gap-2">
                <span class={[
                  "badge badge-xs shrink-0 mt-0.5",
                  log_level_badge(entry.level)
                ]}>
                  {entry.level}
                </span>
                <span class="text-base-content/40 shrink-0">
                  {Calendar.strftime(entry.inserted_at, "%H:%M:%S")}
                </span>
                <span class="badge badge-ghost badge-xs shrink-0">{entry.step}</span>
                <span class="text-base-content/90">{entry.message}</span>
              </div>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :log, :map, required: true
  attr :sidebar_open, :boolean, default: true

  def run_log_show_page(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            :if={!@sidebar_open}
            phx-click="toggle_sidebar"
            class="btn btn-circle btn-ghost btn-sm"
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <.link
            navigate={~p"/runs/#{@run.id}"}
            class="btn btn-ghost btn-sm gap-1"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
            {@run.name}
          </.link>
          <span class="text-base-content/40">/</span>
          <span class="font-semibold">Log: {@log.step}</span>
        </div>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-4">
      <div class="max-w-3xl mx-auto space-y-4">
        <div class="bg-base-200 rounded-xl p-6 space-y-4">
          <div class="flex items-center gap-3">
            <span class={[
              "badge",
              log_level_badge(@log.level)
            ]}>
              {@log.level}
            </span>
            <span class="badge badge-ghost">{@log.step}</span>
            <span class="text-sm text-base-content/50">
              {Calendar.strftime(@log.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
            </span>
          </div>

          <div>
            <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">Message</h4>
            <p class="text-base-content whitespace-pre-wrap">{@log.message}</p>
          </div>

          <%= if not is_list(@log.metadata["messages"]) do %>
            <div>
              <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">
                Metadata
              </h4>
              <%= if @log.metadata == %{} do %>
                <p class="text-base-content/40 italic">No metadata</p>
              <% else %>
                <pre class="bg-base-300 rounded-lg p-4 text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{Jason.encode!(@log.metadata, pretty: true)}</code></pre>
              <% end %>
            </div>
          <% end %>
        </div>

        <%= if is_list(@log.metadata["messages"]) do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content/60 mb-3">
              Context Window ({length(@log.metadata["messages"])} messages)
            </h4>
            <div class="space-y-3">
              <div
                :for={msg <- @log.metadata["messages"]}
                class={[
                  "rounded-lg p-4",
                  log_chat_role_class(msg["role"])
                ]}
              >
                <div class="flex items-center gap-2 mb-2">
                  <span class={[
                    "badge badge-sm",
                    log_chat_role_badge(msg["role"])
                  ]}>
                    {msg["role"]}
                  </span>
                  <span
                    :if={msg["name"]}
                    class="text-xs text-base-content/50"
                  >
                    {msg["name"]}
                  </span>
                </div>
                <div class="whitespace-pre-wrap break-words text-sm">
                  {log_chat_message_content(msg)}
                </div>
                <%= if is_list(msg["tool_calls"]) and msg["tool_calls"] != [] do %>
                  <div class="mt-3 space-y-2">
                    <div
                      :for={tc <- msg["tool_calls"]}
                      class="bg-base-300 rounded-lg p-3 text-xs font-mono"
                    >
                      <div class="font-semibold text-primary mb-1">
                        Tool call: {get_in(tc, ["function", "name"]) || tc["name"]}
                      </div>
                      <pre class="whitespace-pre-wrap break-all text-base-content/70">{format_tool_call_args(tc)}</pre>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <% logs = @run.run_logs
        idx = Enum.find_index(logs, &(&1.id == @log.id))
        prev_log = if idx && idx > 0, do: Enum.at(logs, idx - 1)
        next_log = if idx, do: Enum.at(logs, idx + 1) %>
        <div class="flex items-center justify-between">
          <%= if prev_log do %>
            <.link
              navigate={~p"/runs/#{@run.id}/logs/#{prev_log.id}"}
              class="btn btn-ghost btn-sm gap-1"
            >
              <.icon name="hero-arrow-left-micro" class="size-4" />
              {prev_log.step}
            </.link>
          <% else %>
            <div />
          <% end %>
          <%= if next_log do %>
            <.link
              navigate={~p"/runs/#{@run.id}/logs/#{next_log.id}"}
              class="btn btn-ghost btn-sm gap-1"
            >
              {next_log.step}
              <.icon name="hero-arrow-right-micro" class="size-4" />
            </.link>
          <% else %>
            <div />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :schedules, :list, required: true
  attr :current_user, :map, required: true
  attr :sidebar_open, :boolean, default: true
  attr :confirm_delete_schedule_id, :any, default: nil

  def schedules_page(assigns) do
    ~H"""
    <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <button
            :if={!@sidebar_open}
            phx-click="toggle_sidebar"
            class="btn btn-circle btn-ghost btn-sm"
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
            Schedules
          </h1>
        </div>
        <.link navigate={~p"/schedules/new"} class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-plus-micro" class="size-4" /> New Schedule
        </.link>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-4">
      <.schedules_list schedules={@schedules} current_user={@current_user} />
    </div>
    <ChatComponents.confirm_modal
      :if={@confirm_delete_schedule_id}
      show={@confirm_delete_schedule_id != nil}
      title="Delete Schedule"
      message="Are you sure you want to delete this schedule?"
      confirm_event={"delete_schedule|#{@confirm_delete_schedule_id}"}
      cancel_event="cancel_delete_schedule"
    />
    """
  end

  attr :schedule, :map, required: true
  attr :sidebar_open, :boolean, default: true

  def schedule_show_page(assigns) do
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
          {@schedule.name}
        </h1>
        <span class={[
          "badge badge-sm",
          if(@schedule.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @schedule.enabled, do: "Enabled", else: "Disabled"}
        </span>
      </div>
    </header>
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl space-y-6">
        <div :if={@schedule.description} class="prose">
          <p class="text-base-content/70">{@schedule.description}</p>
        </div>
        <div class="grid grid-cols-3 gap-4">
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Cron</h3>
            <code class="text-sm">{@schedule.cron_expression}</code>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Timezone</h3>
            <p>{@schedule.timezone}</p>
          </div>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content/60 mb-1">Topology</h3>
            <p>{@schedule.topology}</p>
          </div>
        </div>
        <div>
          <h3 class="text-sm font-semibold text-base-content/60 mb-2">Prompt</h3>
          <div class="bg-base-200 rounded-lg p-4 text-sm whitespace-pre-wrap">
            {@schedule.prompt}
          </div>
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

  defp log_level_badge("error"), do: "badge-error"
  defp log_level_badge("warn"), do: "badge-warning"
  defp log_level_badge("info"), do: "badge-info"
  defp log_level_badge("debug"), do: "badge-ghost"
  defp log_level_badge(_), do: "badge-ghost"

  defp format_duration(nil, _), do: "-"

  defp format_duration(started_at, nil) do
    diff = DateTime.diff(DateTime.utc_now(), started_at, :second)
    humanize_seconds(diff)
  end

  defp format_duration(started_at, completed_at) do
    diff = DateTime.diff(completed_at, started_at, :second)
    humanize_seconds(diff)
  end

  defp humanize_seconds(s) when s < 0, do: "0s"
  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"

  defp humanize_seconds(s),
    do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m #{rem(s, 60)}s"

  defp log_chat_role_class("system"), do: "bg-warning/10 border border-warning/20"
  defp log_chat_role_class("user"), do: "bg-primary/10 border border-primary/20"
  defp log_chat_role_class("assistant"), do: "bg-base-200 border border-base-300"
  defp log_chat_role_class("tool"), do: "bg-success/10 border border-success/20"
  defp log_chat_role_class(_), do: "bg-base-200"

  defp log_chat_role_badge("system"), do: "badge-warning"
  defp log_chat_role_badge("user"), do: "badge-primary"
  defp log_chat_role_badge("assistant"), do: "badge-neutral"
  defp log_chat_role_badge("tool"), do: "badge-success"
  defp log_chat_role_badge(_), do: "badge-ghost"

  defp log_chat_message_content(%{"role" => "system", "content" => content})
       when is_binary(content),
       do: content

  defp log_chat_message_content(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  defp log_chat_message_content(%{"content" => content}) when is_binary(content), do: content
  defp log_chat_message_content(_), do: ""

  defp format_tool_call_args(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> args
    end
  end

  defp format_tool_call_args(%{"function" => %{"arguments" => args}}) when is_map(args) do
    Jason.encode!(args, pretty: true)
  end

  defp format_tool_call_args(%{"input" => input}) when is_map(input) do
    Jason.encode!(input, pretty: true)
  end

  defp format_tool_call_args(_), do: ""

  defp build_assigned_servers(agent, builtin_servers) do
    db_entries =
      Enum.map(agent.agent_tools, fn tool ->
        %{
          id: tool.mcp_server_id,
          name: tool.mcp_server.name,
          description: tool.mcp_server.description,
          builtin: false
        }
      end)

    builtin_entries =
      Enum.map(builtin_servers, fn s ->
        %{id: s.id, name: s.name, description: s.description, builtin: true}
      end)

    db_entries ++ builtin_entries
  end
end
