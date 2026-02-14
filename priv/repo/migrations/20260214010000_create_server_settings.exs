defmodule Liteskill.Repo.Migrations.CreateServerSettings do
  use Ecto.Migration

  def change do
    create table(:server_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :registration_open, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end
  end
end
