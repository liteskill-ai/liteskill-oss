defmodule Liteskill.Repo.Migrations.AddDocumentNesting do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :parent_document_id,
          references(:documents, type: :binary_id, on_delete: :delete_all)

      add :position, :integer, null: false, default: 0
    end

    create index(:documents, [:parent_document_id])
  end
end
