defmodule Liteskill.Instances.InstanceTask do
  @moduledoc """
  Schema for instance tasks — individual steps within an instance execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending running completed failed skipped)

  schema "instance_tasks" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :position, :integer, default: 0
    field :input_summary, :string
    field :output_summary, :string
    field :error, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :instance, Liteskill.Instances.Instance
    belongs_to :agent_definition, Liteskill.Agents.AgentDefinition

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :position,
      :input_summary,
      :output_summary,
      :error,
      :duration_ms,
      :started_at,
      :completed_at,
      :instance_id,
      :agent_definition_id
    ])
    |> validate_required([:name, :instance_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:agent_definition_id)
  end
end
