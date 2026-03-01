defmodule Liteskill.Rbac.AgentRole do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_roles" do
    belongs_to :agent_definition, Liteskill.Agents.AgentDefinition
    belongs_to :role, Liteskill.Rbac.Role

    timestamps(type: :utc_datetime)
  end

  def changeset(agent_role, attrs) do
    agent_role
    |> cast(attrs, [:agent_definition_id, :role_id])
    |> validate_required([:agent_definition_id, :role_id])
    |> unique_constraint([:agent_definition_id, :role_id])
    |> foreign_key_constraint(:agent_definition_id)
    |> foreign_key_constraint(:role_id)
  end
end
