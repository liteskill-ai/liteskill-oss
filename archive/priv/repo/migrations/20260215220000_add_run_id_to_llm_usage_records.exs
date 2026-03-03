defmodule Liteskill.Repo.Migrations.AddRunIdToLlmUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:llm_usage_records) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:llm_usage_records, [:run_id])
  end
end
