defmodule Liteskill.Repo.Migrations.AddSectionComments do
  use Ecto.Migration

  def change do
    create table(:section_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :body, :text, null: false
      add :author_type, :string, null: false
      add :status, :string, null: false, default: "open"

      add :section_id,
          references(:report_sections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:section_comments, [:section_id])
    create index(:section_comments, [:user_id])
  end
end
