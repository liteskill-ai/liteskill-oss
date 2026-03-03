defmodule Liteskill.Repo.Migrations.AddSetupDismissedToServerSettings do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add :setup_dismissed, :boolean, default: false, null: false
    end
  end
end
