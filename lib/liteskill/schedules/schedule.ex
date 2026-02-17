defmodule Liteskill.Schedules.Schedule do
  @moduledoc """
  Schema for schedules — cron-like scheduling that creates runs on a recurring basis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_topologies ~w(pipeline parallel debate hierarchical round_robin)
  @valid_statuses ~w(active inactive)

  schema "schedules" do
    field :name, :string
    field :description, :string
    field :cron_expression, :string
    field :timezone, :string, default: "UTC"
    field :enabled, :boolean, default: true
    field :status, :string, default: "active"
    field :prompt, :string
    field :topology, :string, default: "pipeline"
    field :context, :map, default: %{}
    field :timeout_ms, :integer, default: 3_600_000
    field :max_iterations, :integer, default: 50
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime

    belongs_to :team_definition, Liteskill.Teams.TeamDefinition
    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def valid_topologies, do: @valid_topologies

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :name,
      :description,
      :cron_expression,
      :timezone,
      :enabled,
      :status,
      :prompt,
      :topology,
      :context,
      :timeout_ms,
      :max_iterations,
      :last_run_at,
      :next_run_at,
      :team_definition_id,
      :user_id
    ])
    |> validate_required([:name, :cron_expression, :prompt, :user_id])
    |> validate_inclusion(:topology, @valid_topologies)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_cron_expression()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:team_definition_id)
    |> unique_constraint([:name, :user_id])
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      cron ->
        parts = String.split(cron)

        if length(parts) in [5, 6] do
          changeset
        else
          add_error(
            changeset,
            :cron_expression,
            "must be a valid cron expression (5 or 6 fields)"
          )
        end
    end
  end
end
