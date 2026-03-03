defmodule Liteskill.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:user_id])

    create table(:report_sections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false

      add :parent_section_id,
          references(:report_sections, type: :binary_id, on_delete: :delete_all)

      add :title, :string, null: false
      add :content, :text
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:report_sections, [:report_id])
    create index(:report_sections, [:parent_section_id])

    create table(:report_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :report_id, references(:reports, type: :binary_id, on_delete: :delete_all), null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, :binary_id
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create index(:report_acls, [:report_id])
    create index(:report_acls, [:user_id])
    create index(:report_acls, [:group_id])

    create unique_index(:report_acls, [:report_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :report_acls_report_id_user_id_index
           )

    create unique_index(:report_acls, [:report_id, :group_id],
             where: "group_id IS NOT NULL",
             name: :report_acls_report_id_group_id_index
           )

    create constraint(:report_acls, :report_acl_user_or_group_required,
             check:
               "(user_id IS NOT NULL AND group_id IS NULL) OR (user_id IS NULL AND group_id IS NOT NULL)"
           )
  end
end
