defmodule Liteskill.Teams.TeamMember do
  @moduledoc """
  Join table linking team definitions to agent definitions with role and position.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_members" do
    field :role, :string, default: "worker"
    field :description, :string
    field :position, :integer, default: 0

    belongs_to :team_definition, Liteskill.Teams.TeamDefinition
    belongs_to :agent_definition, Liteskill.Agents.AgentDefinition

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role, :description, :position, :team_definition_id, :agent_definition_id])
    |> validate_required([:team_definition_id, :agent_definition_id])
    |> foreign_key_constraint(:team_definition_id)
    |> foreign_key_constraint(:agent_definition_id)
    |> unique_constraint([:team_definition_id, :agent_definition_id],
      name: :team_members_unique_idx
    )
  end
end
