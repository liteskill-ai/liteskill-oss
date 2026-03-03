defmodule Liteskill.Repo.Migrations.CreateInstanceLogs do
  use Ecto.Migration

  def change do
    create table(:instance_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :level, :string, null: false
      add :step, :string, null: false
      add :message, :text, null: false
      add :metadata, :map, default: %{}

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:instance_logs, [:instance_id])
  end
end
