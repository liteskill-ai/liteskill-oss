defmodule Liteskill.Repo.Migrations.CreateEntityAcls do
  use Ecto.Migration

  def change do
    create table(:entity_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :entity_type, :string, null: false
      add :entity_id, :binary_id, null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, :binary_id
      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create index(:entity_acls, [:entity_type, :entity_id])
    create index(:entity_acls, [:user_id])
    create index(:entity_acls, [:group_id])

    create unique_index(:entity_acls, [:entity_type, :entity_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :entity_acls_entity_user_idx
           )

    create unique_index(:entity_acls, [:entity_type, :entity_id, :group_id],
             where: "group_id IS NOT NULL",
             name: :entity_acls_entity_group_idx
           )

    create constraint(:entity_acls, :entity_acl_user_or_group,
             check:
               "(user_id IS NOT NULL AND group_id IS NULL) OR (user_id IS NULL AND group_id IS NOT NULL)"
           )
  end
end
