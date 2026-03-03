defmodule Liteskill.Repo.Migrations.CreateRbacTables do
  use Ecto.Migration

  def change do
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :system, :boolean, default: false, null: false
      add :permissions, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    create table(:user_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_roles, [:user_id, :role_id])
    create index(:user_roles, [:role_id])

    create table(:group_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_roles, [:group_id, :role_id])
    create index(:group_roles, [:role_id])
  end
end
