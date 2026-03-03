defmodule Liteskill.Repo.Migrations.CreateConversationAcls do
  use Ecto.Migration

  def change do
    create table(:conversation_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, :binary_id
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create index(:conversation_acls, [:conversation_id])
    create index(:conversation_acls, [:user_id])
    create index(:conversation_acls, [:group_id])

    create unique_index(:conversation_acls, [:conversation_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :conversation_acls_conversation_id_user_id_index
           )

    create unique_index(:conversation_acls, [:conversation_id, :group_id],
             where: "group_id IS NOT NULL",
             name: :conversation_acls_conversation_id_group_id_index
           )

    # Exactly one of user_id/group_id must be non-null
    create constraint(:conversation_acls, :user_or_group_required,
             check:
               "(user_id IS NOT NULL AND group_id IS NULL) OR (user_id IS NULL AND group_id IS NOT NULL)"
           )
  end
end
