defmodule Liteskill.Repo.Migrations.CreateUserSessionsAndAuthEvents do
  use Ecto.Migration

  def change do
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :ip_address, :string
      add :user_agent, :string
      add :last_active_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_sessions, [:user_id])
    create index(:user_sessions, [:expires_at])

    create table(:auth_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :ip_address, :string
      add :user_agent, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:auth_events, [:user_id, :inserted_at])
    create index(:auth_events, [:event_type, :inserted_at])
  end
end
