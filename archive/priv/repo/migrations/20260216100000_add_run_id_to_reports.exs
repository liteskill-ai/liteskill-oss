defmodule Liteskill.Repo.Migrations.AddRunIdToReports do
  use Ecto.Migration

  def change do
    alter table(:reports) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:reports, [:run_id])
  end
end
