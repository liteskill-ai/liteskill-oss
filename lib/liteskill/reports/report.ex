defmodule Liteskill.Reports.Report do
  @moduledoc "Schema for agent-generated reports."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reports" do
    field :title, :string

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :run, Liteskill.Runs.Run
    has_many :sections, Liteskill.Reports.ReportSection

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:title, :user_id, :run_id])
    |> validate_required([:title, :user_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:run_id)
  end
end
