defmodule Liteskill.Runs.RunLog do
  @moduledoc """
  Schema for run execution logs — structured step-by-step records
  of what happened during a run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_logs" do
    field :level, :string
    field :step, :string
    field :message, :string
    field :metadata, :map, default: %{}

    belongs_to :run, Liteskill.Runs.Run

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:level, :step, :message, :metadata, :run_id])
    |> validate_required([:level, :step, :message, :run_id])
    |> validate_inclusion(:level, ~w(debug info warn error))
    |> foreign_key_constraint(:run_id)
  end
end
