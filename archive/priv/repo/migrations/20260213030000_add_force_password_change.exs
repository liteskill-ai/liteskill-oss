defmodule Liteskill.Repo.Migrations.AddForcePasswordChange do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :force_password_change, :boolean, default: false, null: false
    end
  end
end
