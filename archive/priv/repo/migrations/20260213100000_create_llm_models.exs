defmodule Liteskill.Repo.Migrations.CreateLlmModels do
  use Ecto.Migration

  def change do
    create table(:llm_models, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :provider, :string, null: false
      add :model_id, :string, null: false
      add :api_key, :text
      add :provider_config, :text
      add :instance_wide, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:llm_models, [:user_id])
    create unique_index(:llm_models, [:provider, :model_id, :user_id])

    alter table(:conversations) do
      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:conversations, [:llm_model_id])
  end
end
