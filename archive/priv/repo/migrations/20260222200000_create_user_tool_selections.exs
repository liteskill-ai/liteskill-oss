defmodule Liteskill.Repo.Migrations.CreateUserToolSelections do
  use Ecto.Migration

  def change do
    create table(:user_tool_selections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :server_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_tool_selections, [:user_id, :server_id])
    create index(:user_tool_selections, [:user_id])
  end
end
