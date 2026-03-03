defmodule Liteskill.Repo.Migrations.AddEmbeddingModelToServerSettings do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add :embedding_model_id,
          references(:llm_models, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:server_settings, [:embedding_model_id])
  end
end
