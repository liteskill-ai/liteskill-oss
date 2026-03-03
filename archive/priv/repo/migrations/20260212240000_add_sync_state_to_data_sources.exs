defmodule Liteskill.Repo.Migrations.AddSyncStateToDataSources do
  use Ecto.Migration

  def change do
    alter table(:data_sources) do
      add :sync_cursor, :map, default: %{}
      add :sync_status, :string, default: "idle"
      add :last_synced_at, :utc_datetime
      add :last_sync_error, :string
      add :sync_document_count, :integer, default: 0
    end
  end
end
