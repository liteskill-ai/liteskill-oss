defmodule Liteskill.Repo.Migrations.AlterRagChunksVariableVectorDimensions do
  use Ecto.Migration

  def up do
    # Drop HNSW index before altering column type
    execute "DROP INDEX IF EXISTS rag_chunks_embedding_index"

    # Remove fixed 1024 dimension constraint — allow any dimension.
    # Vector search still works (sequential scan). The HNSW index will be
    # recreated by the application after re-embedding populates vectors
    # of uniform dimension.
    execute "ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE vector USING embedding::vector"
  end

  def down do
    execute "DROP INDEX IF EXISTS rag_chunks_embedding_index"

    execute "ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE vector(1024) USING embedding::vector(1024)"

    execute "CREATE INDEX rag_chunks_embedding_index ON rag_chunks USING hnsw (embedding vector_cosine_ops)"
  end
end
