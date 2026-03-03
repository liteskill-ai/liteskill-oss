defmodule Liteskill.Repo.Migrations.AddInsertedAtIndexToLlmUsageRecords do
  use Ecto.Migration

  def change do
    create index(:llm_usage_records, [:inserted_at])
  end
end
