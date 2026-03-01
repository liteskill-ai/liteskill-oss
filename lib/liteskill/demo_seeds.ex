defmodule Liteskill.DemoSeeds do
  @moduledoc """
  Seeds the Sandwich Builder demo agents and team on startup.

  Creates 6 agents and 1 pipeline team, idempotently — skips any
  that already exist for the admin user.
  """

  use Boundary, top_level?: true, deps: [Liteskill.Accounts, Liteskill.Agents, Liteskill.Teams]

  require Logger

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.Agents.AgentDefinition
  alias Liteskill.Teams.TeamDefinition
  alias Liteskill.Repo

  import Ecto.Query

  @agent_specs [
    %{
      name: "Intent Agent",
      strategy: "direct",
      description: "Extracts constraints and preferences from user input.",
      backstory:
        "You are an intent extraction specialist. You parse natural language requests " <>
          "into structured constraints such as protein level, calorie maximums, and dietary restrictions.",
      system_prompt:
        "You are the Intent Agent. Given a user's sandwich request, extract structured constraints:\n" <>
          "- protein_level (low, medium, high)\n" <>
          "- calories_max (integer)\n" <>
          "- dietary_restrictions (list of strings, e.g. gluten-free, vegan)\n" <>
          "- flavor_preferences (list of strings)\n\n" <>
          "Return a JSON object with these fields. If a field is not specified, omit it.",
      role: "analyst",
      position: 0
    },
    %{
      name: "Recipe RAG Agent",
      strategy: "react",
      description: "Retrieves candidate sandwich recipes matching the parsed intent.",
      backstory:
        "You are a recipe retrieval specialist with access to a vast sandwich recipe database. " <>
          "You embed queries and retrieve the top matching recipes based on nutritional and flavor criteria.",
      system_prompt:
        "You are the Recipe RAG Agent. Given structured intent constraints, retrieve candidate " <>
          "sandwich recipes that match. Return a list of recipe objects, each with: name, ingredients, " <>
          "estimated_calories, protein_grams, and preparation_summary.",
      role: "researcher",
      position: 1
    },
    %{
      name: "Inventory Agent",
      strategy: "react",
      description: "Queries available ingredients against candidate recipes.",
      backstory:
        "You are an inventory management specialist. You check what ingredients are currently " <>
          "available and flag any that are missing from the candidate recipes.",
      system_prompt:
        "You are the Inventory Agent. Given a list of candidate recipes, check ingredient availability. " <>
          "For each recipe, return which ingredients are available and which are missing. " <>
          "Use the get_inventory tool if available, otherwise reason about common ingredient availability.",
      role: "researcher",
      position: 2
    },
    %{
      name: "Substitution Agent",
      strategy: "chain_of_thought",
      description: "Replaces missing ingredients with suitable alternatives.",
      backstory:
        "You are a culinary substitution expert. You know which ingredients can replace others " <>
          "while maintaining flavor profiles, nutritional targets, and dietary compliance.",
      system_prompt:
        "You are the Substitution Agent. Given candidate recipes and inventory information, " <>
          "propose substitutions for any missing ingredients. Consider:\n" <>
          "- Nutritional equivalence (protein, calories)\n" <>
          "- Flavor compatibility\n" <>
          "- Dietary restriction compliance\n\n" <>
          "Return the updated recipe with substitutions clearly marked.",
      role: "planner",
      position: 3
    },
    %{
      name: "Execution Planner",
      strategy: "chain_of_thought",
      description:
        "Generates step-by-step preparation instructions from the recipe and substitutions.",
      backstory:
        "You are a culinary execution planner. You transform recipes and substitution lists " <>
          "into clear, ordered preparation steps that anyone can follow.",
      system_prompt:
        "You are the Execution Planner. Given a finalized recipe (with substitutions applied), " <>
          "generate detailed step-by-step preparation instructions. Include:\n" <>
          "- Prep steps (washing, slicing, etc.)\n" <>
          "- Assembly order\n" <>
          "- Timing notes\n" <>
          "- Final presentation suggestions",
      role: "planner",
      position: 4
    },
    %{
      name: "Quality Reviewer",
      strategy: "react",
      description:
        "Validates nutrition constraints, checks for missing steps, and returns a validation score.",
      backstory:
        "You are a quality assurance reviewer for sandwich recipes. You validate that the final " <>
          "execution plan meets all original constraints and contains no logical gaps.",
      system_prompt:
        "You are the Quality Reviewer. Given the execution plan and original intent constraints, validate:\n" <>
          "- Constraint satisfaction (calories, protein, dietary restrictions)\n" <>
          "- Completeness (no missing preparation steps)\n" <>
          "- Logical consistency (steps are in correct order)\n\n" <>
          "Return a validation_score between 0.0 and 1.0, along with any issues found.",
      role: "reviewer",
      position: 5
    }
  ]

  @team_spec %{
    name: "Sandwich Builder Pipeline",
    description:
      "A multi-agent pipeline that builds custom sandwich recipes from user preferences.",
    default_topology: "pipeline",
    aggregation_strategy: "last",
    shared_context:
      "This team implements an autonomous sandwich builder workflow. " <>
        "The pipeline flows: Intent extraction → Recipe retrieval → Inventory check → " <>
        "Ingredient substitution → Execution planning → Quality review. " <>
        "Each agent passes its output to the next agent in the chain."
  }

  def ensure_demo_agents do
    admin = Accounts.get_user_by_email(User.admin_email())

    if admin do
      agents = ensure_agents(admin.id)
      ensure_team(admin.id, agents)
      Logger.info("Demo seeds: Sandwich Builder agents and team ready")
    else
      Logger.warning("Demo seeds: admin user not found, skipping")
    end
  rescue
    e ->
      Logger.error("Demo seeds failed: #{Exception.message(e)}")
  end

  defp ensure_agents(user_id) do
    Enum.map(@agent_specs, fn spec ->
      case find_agent(spec.name, user_id) do
        nil ->
          case Liteskill.Agents.create_agent(%{
                 name: spec.name,
                 description: spec.description,
                 backstory: spec.backstory,
                 system_prompt: spec.system_prompt,
                 strategy: spec.strategy,
                 user_id: user_id
               }) do
            {:ok, agent} ->
              Logger.info("Demo seeds: created agent #{spec.name}")
              Map.merge(spec, %{id: agent.id})

            {:error, reason} ->
              Logger.error("Demo seeds: failed to create agent #{spec.name}: #{inspect(reason)}")
              nil
          end

        existing ->
          Map.merge(spec, %{id: existing.id})
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ensure_team(user_id, agents) do
    case find_team(@team_spec.name, user_id) do
      nil ->
        case Liteskill.Teams.create_team(Map.put(@team_spec, :user_id, user_id)) do
          {:ok, team} ->
            Logger.info("Demo seeds: created team #{@team_spec.name}")

            Enum.each(agents, fn agent ->
              {:ok, _member} =
                Liteskill.Teams.add_member(team.id, agent.id, user_id, %{
                  role: agent.role,
                  description: agent.description,
                  position: agent.position
                })
            end)

          {:error, reason} ->
            Logger.error("Demo seeds: failed to create team: #{inspect(reason)}")
        end

      _existing ->
        :ok
    end
  end

  defp find_agent(name, user_id) do
    AgentDefinition
    |> where([a], a.name == ^name and a.user_id == ^user_id)
    |> Repo.one()
  end

  defp find_team(name, user_id) do
    TeamDefinition
    |> where([t], t.name == ^name and t.user_id == ^user_id)
    |> Repo.one()
  end
end
