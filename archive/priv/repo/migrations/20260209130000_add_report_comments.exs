defmodule Liteskill.Repo.Migrations.AddReportComments do
  use Ecto.Migration

  def change do
    alter table(:section_comments) do
      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all)
    end

    create index(:section_comments, [:report_id])

    # Backfill report_id from the section's report
    execute(
      """
      UPDATE section_comments sc
      SET report_id = rs.report_id
      FROM report_sections rs
      WHERE sc.section_id = rs.id
      """,
      ""
    )

    # Now make report_id non-null and section_id nullable
    alter table(:section_comments) do
      modify :report_id, :binary_id, null: false, from: {:binary_id, null: true}
      modify :section_id, :binary_id, null: true, from: {:binary_id, null: false}
    end
  end
end
