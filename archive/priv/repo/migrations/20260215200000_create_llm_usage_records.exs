defmodule Liteskill.Repo.Migrations.CreateLlmUsageRecords do
  use Ecto.Migration

  def change do
    create table(:llm_usage_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :nilify_all)
      add :message_id, :binary_id
      add :model_id, :string, null: false
      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :reasoning_tokens, :integer, default: 0
      add :cached_tokens, :integer, default: 0
      add :cache_creation_tokens, :integer, default: 0
      add :input_cost, :decimal
      add :output_cost, :decimal
      add :reasoning_cost, :decimal
      add :total_cost, :decimal
      add :latency_ms, :integer
      add :call_type, :string, null: false
      add :tool_round, :integer, default: 0

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:llm_usage_records, [:user_id, :inserted_at])
    create index(:llm_usage_records, [:conversation_id])
    create index(:llm_usage_records, [:user_id, :model_id])
    create index(:llm_usage_records, [:llm_model_id])
  end
end
