defmodule Liteskill.Repo.Migrations.CreateDataSources do
  use Ecto.Migration

  def change do
    create table(:data_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :source_type, :string, null: false
      add :description, :string
      add :metadata, :map, default: %{}
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:data_sources, [:user_id])

    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :content, :text
      add :content_type, :string, null: false, default: "markdown"
      add :metadata, :map, default: %{}
      add :source_ref, :string, null: false
      add :slug, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:source_ref])
    create index(:documents, [:user_id])
    create unique_index(:documents, [:source_ref, :slug], name: :documents_source_ref_slug_index)
  end
end
