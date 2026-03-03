defmodule Liteskill.Repo.Migrations.FixUsageRecordsUserOnDelete do
  use Ecto.Migration

  def change do
    alter table(:llm_usage_records) do
      modify :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        from: references(:users, type: :binary_id, on_delete: :nothing)
    end
  end
end
