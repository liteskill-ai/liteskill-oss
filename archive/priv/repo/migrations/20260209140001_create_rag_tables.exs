defmodule Liteskill.Repo.Migrations.CreateRagTables do
  use Ecto.Migration

  def change do
    create table(:rag_collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :embedding_dimensions, :integer, null: false, default: 1024
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_collections, [:user_id])

    create table(:rag_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :source_type, :string, null: false, default: "manual"
      add :metadata, :map, default: %{}

      add :collection_id,
          references(:rag_collections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_sources, [:collection_id])
    create index(:rag_sources, [:user_id])

    create table(:rag_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :content, :text
      add :metadata, :map, default: %{}
      add :chunk_count, :integer, default: 0
      add :status, :string, null: false, default: "pending"

      add :source_id, references(:rag_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_documents, [:source_id])
    create index(:rag_documents, [:user_id])

    create table(:rag_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false
      add :position, :integer, null: false
      add :metadata, :map, default: %{}
      add :token_count, :integer

      add :document_id, references(:rag_documents, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_chunks, [:document_id])

    execute(
      "ALTER TABLE rag_chunks ADD COLUMN embedding vector(1024)",
      "ALTER TABLE rag_chunks DROP COLUMN embedding"
    )

    execute(
      "CREATE INDEX rag_chunks_embedding_index ON rag_chunks USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX rag_chunks_embedding_index"
    )
  end
end
