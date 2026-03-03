defmodule Liteskill.Reports.ReportSection do
  @moduledoc "Schema for individual sections within a report."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "report_sections" do
    field :title, :string
    field :content, :string
    field :position, :integer, default: 0

    belongs_to :report, Liteskill.Reports.Report
    belongs_to :parent_section, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_section_id
    has_many :comments, Liteskill.Reports.SectionComment, foreign_key: :section_id

    timestamps(type: :utc_datetime)
  end

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:title, :content, :position, :report_id, :parent_section_id])
    |> validate_required([:title, :report_id])
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:parent_section_id)
  end
end
