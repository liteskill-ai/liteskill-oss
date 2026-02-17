defmodule Liteskill.Runs.Run do
  @moduledoc """
  Schema for runs — runtime task executions.

  A run represents a single execution of a task, optionally assigned to a team.
  It tracks status, deliverables, and timing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_topologies ~w(pipeline parallel debate hierarchical round_robin)
  @valid_statuses ~w(pending running completed failed cancelled)

  schema "runs" do
    field :name, :string
    field :description, :string
    field :prompt, :string
    field :topology, :string, default: "pipeline"
    field :status, :string, default: "pending"
    field :context, :map, default: %{}
    field :deliverables, :map, default: %{}
    field :error, :string
    field :timeout_ms, :integer, default: 3_600_000
    field :max_iterations, :integer, default: 50
    field :cost_limit, :decimal
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :team_definition, Liteskill.Teams.TeamDefinition
    belongs_to :user, Liteskill.Accounts.User
    has_many :run_tasks, Liteskill.Runs.RunTask, preload_order: [asc: :position]
    has_many :run_logs, Liteskill.Runs.RunLog, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  def valid_topologies, do: @valid_topologies
  def valid_statuses, do: @valid_statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :name,
      :description,
      :prompt,
      :topology,
      :status,
      :context,
      :deliverables,
      :error,
      :timeout_ms,
      :max_iterations,
      :cost_limit,
      :started_at,
      :completed_at,
      :team_definition_id,
      :user_id
    ])
    |> validate_required([:name, :prompt, :user_id])
    |> validate_inclusion(:topology, @valid_topologies)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:team_definition_id)
  end
end
