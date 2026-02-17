defmodule Liteskill.Reports.SectionComment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "section_comments" do
    field :body, :string
    field :author_type, :string
    field :status, :string, default: "open"

    belongs_to :report, Liteskill.Reports.Report
    belongs_to :section, Liteskill.Reports.ReportSection
    belongs_to :user, Liteskill.Accounts.User
    belongs_to :parent_comment, __MODULE__
    has_many :replies, __MODULE__, foreign_key: :parent_comment_id

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [
      :body,
      :author_type,
      :status,
      :report_id,
      :section_id,
      :user_id,
      :parent_comment_id
    ])
    |> validate_required([:body, :author_type, :report_id, :user_id])
    |> validate_inclusion(:author_type, ["user", "agent"])
    |> validate_inclusion(:status, ["open", "addressed"])
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:section_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_comment_id)
  end
end
