defmodule Liteskill.Repo.Migrations.ScopeDocumentSlugToParent do
  use Ecto.Migration

  def change do
    drop unique_index(:documents, [:source_ref, :slug], name: :documents_source_ref_slug_index)

    create unique_index(:documents, [:source_ref, :parent_document_id, :slug],
             name: :documents_source_ref_parent_slug_index
           )

    # Root-level documents (spaces) still need unique slugs within source_ref
    create unique_index(:documents, [:source_ref, :slug],
             where: "parent_document_id IS NULL",
             name: :documents_source_ref_root_slug_index
           )
  end
end
