defmodule Liteskill.Agents.AgentDefinition do
  @moduledoc """
  Schema for agent definitions — the "character sheet" for an AI agent.

  Each definition specifies a name, backstory, opinions, strategy, and
  references an LLM model. Tools are assigned via the `agent_tools` join table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_strategies ~w(react chain_of_thought tree_of_thoughts direct)
  @valid_statuses ~w(active inactive)

  schema "agent_definitions" do
    field :name, :string
    field :description, :string
    field :backstory, :string
    field :opinions, :map, default: %{}
    field :system_prompt, :string
    field :strategy, :string, default: "react"
    field :config, :map, default: %{}
    field :status, :string, default: "active"

    belongs_to :llm_model, Liteskill.LlmModels.LlmModel
    belongs_to :user, Liteskill.Accounts.User
    has_many :agent_tools, Liteskill.Agents.AgentTool
    has_many :team_members, Liteskill.Teams.TeamMember

    timestamps(type: :utc_datetime)
  end

  def valid_strategies, do: @valid_strategies

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :description,
      :backstory,
      :opinions,
      :system_prompt,
      :strategy,
      :config,
      :status,
      :llm_model_id,
      :user_id
    ])
    |> validate_required([:name, :user_id])
    |> validate_inclusion(:strategy, @valid_strategies)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:llm_model_id)
    |> unique_constraint([:name, :user_id])
  end
end
