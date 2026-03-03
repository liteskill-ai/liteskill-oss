defmodule Liteskill.Repo.Migrations.AddExternalIdToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :external_id, :string
      add :content_hash, :string
    end

    create index(:documents, [:source_ref, :external_id],
             name: :documents_source_ref_external_id_index
           )
  end
end
