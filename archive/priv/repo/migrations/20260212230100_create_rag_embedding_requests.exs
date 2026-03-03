defmodule Liteskill.Repo.Migrations.CreateRagEmbeddingRequests do
  use Ecto.Migration

  def change do
    create table(:rag_embedding_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_type, :string, null: false
      add :status, :string, null: false
      add :latency_ms, :integer
      add :input_count, :integer
      add :token_count, :integer
      add :model_id, :string
      add :error_message, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:rag_embedding_requests, [:user_id])
    create index(:rag_embedding_requests, [:status])
    create index(:rag_embedding_requests, [:inserted_at])
  end
end
