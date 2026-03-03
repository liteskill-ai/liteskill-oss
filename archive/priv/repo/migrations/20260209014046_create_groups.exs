defmodule Liteskill.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :created_by, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:groups, [:created_by])

    create table(:group_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_memberships, [:group_id, :user_id])
    create index(:group_memberships, [:user_id])
    create index(:group_memberships, [:group_id])

    # Add foreign key from conversation_acls.group_id to groups
    alter table(:conversation_acls) do
      modify :group_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        from: :binary_id
    end
  end
end
