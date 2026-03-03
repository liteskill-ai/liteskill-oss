defmodule Liteskill.Repo.Migrations.AddEntityAclsGroupFk do
  use Ecto.Migration

  def change do
    # Remove orphaned rows first (group_id references non-existent groups)
    execute(
      "DELETE FROM entity_acls WHERE group_id IS NOT NULL AND group_id NOT IN (SELECT id FROM groups)",
      "SELECT 1"
    )

    alter table(:entity_acls) do
      modify :group_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        from: :binary_id
    end
  end
end
