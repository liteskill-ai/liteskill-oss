defmodule Liteskill.Repo.Migrations.ChangeLastSyncErrorToText do
  use Ecto.Migration

  def change do
    alter table(:data_sources) do
      modify :last_sync_error, :text, from: :string
    end
  end
end
