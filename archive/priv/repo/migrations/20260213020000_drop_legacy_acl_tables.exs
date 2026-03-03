defmodule Liteskill.Repo.Migrations.DropLegacyAclTables do
  use Ecto.Migration

  def up do
    # Migrate conversation_acls → entity_acls
    execute("""
    INSERT INTO entity_acls (id, entity_type, entity_id, user_id, group_id, role, inserted_at, updated_at)
    SELECT id, 'conversation', conversation_id, user_id, group_id,
      CASE WHEN role = 'member' THEN 'manager' ELSE role END,
      inserted_at, updated_at
    FROM conversation_acls
    ON CONFLICT DO NOTHING
    """)

    # Migrate report_acls → entity_acls
    execute("""
    INSERT INTO entity_acls (id, entity_type, entity_id, user_id, group_id, role, inserted_at, updated_at)
    SELECT id, 'report', report_id, user_id, group_id,
      CASE WHEN role = 'member' THEN 'manager' ELSE role END,
      inserted_at, updated_at
    FROM report_acls
    ON CONFLICT DO NOTHING
    """)

    drop(table(:conversation_acls))
    drop(table(:report_acls))
  end

  def down do
    create table(:conversation_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, :binary_id
      timestamps(type: :utc_datetime)
    end

    create table(:report_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"
      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, :binary_id
      timestamps(type: :utc_datetime)
    end

    # Copy data back from entity_acls
    execute("""
    INSERT INTO conversation_acls (id, conversation_id, user_id, group_id, role, inserted_at, updated_at)
    SELECT id, entity_id, user_id, group_id,
      CASE WHEN role = 'manager' THEN 'member' ELSE role END,
      inserted_at, updated_at
    FROM entity_acls
    WHERE entity_type = 'conversation'
    ON CONFLICT DO NOTHING
    """)

    execute("""
    INSERT INTO report_acls (id, report_id, user_id, group_id, role, inserted_at, updated_at)
    SELECT id, entity_id, user_id, group_id,
      CASE WHEN role = 'manager' THEN 'member' ELSE role END,
      inserted_at, updated_at
    FROM entity_acls
    WHERE entity_type = 'report'
    ON CONFLICT DO NOTHING
    """)
  end
end
