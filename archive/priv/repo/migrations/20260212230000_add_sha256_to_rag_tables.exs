defmodule Liteskill.Repo.Migrations.AddSha256ToRagTables do
  use Ecto.Migration

  def change do
    alter table(:rag_documents) do
      add :content_hash, :string, size: 64
    end

    alter table(:rag_chunks) do
      add :content_hash, :string, size: 64
    end

    create index(:rag_documents, [:content_hash])
    create index(:rag_chunks, [:content_hash])
  end
end
