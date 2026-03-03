defmodule Liteskill.Repo.Migrations.CreateChatProjections do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :stream_id, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string
      add :model_id, :string
      add :system_prompt, :text
      add :status, :string, null: false, default: "active"

      add :parent_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :fork_at_version, :integer
      add :message_count, :integer, null: false, default: 0
      add :last_message_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversations, [:stream_id])
    create index(:conversations, [:user_id])
    create index(:conversations, [:parent_conversation_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :content, :text
      add :status, :string, null: false, default: "complete"
      add :model_id, :string
      add :stop_reason, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :latency_ms, :integer
      add :stream_version, :integer
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:conversation_id, :position])

    create table(:message_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :chunk_index, :integer, null: false
      add :content_block_index, :integer, null: false, default: 0
      add :delta_type, :string, null: false, default: "text_delta"
      add :delta_text, :text

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:message_chunks, [:message_id])
    create index(:message_chunks, [:message_id, :chunk_index])

    create table(:tool_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tool_use_id, :string, null: false
      add :tool_name, :string, null: false
      add :input, :map
      add :output, :map
      add :status, :string, null: false, default: "started"
      add :duration_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:tool_calls, [:message_id])
    create index(:tool_calls, [:tool_use_id])
  end
end
