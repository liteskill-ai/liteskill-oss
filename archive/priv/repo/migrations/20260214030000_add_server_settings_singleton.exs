defmodule Liteskill.Repo.Migrations.AddServerSettingsSingleton do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add :singleton, :boolean, null: false, default: true
    end

    create unique_index(:server_settings, [:singleton])
  end
end
