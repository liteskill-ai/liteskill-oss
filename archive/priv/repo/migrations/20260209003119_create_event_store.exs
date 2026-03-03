defmodule Liteskill.Repo.Migrations.CreateEventStore do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :stream_id, :string, null: false
      add :stream_version, :integer, null: false
      add :event_type, :string, null: false
      add :data, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:events, [:stream_id, :stream_version])
    create index(:events, [:stream_id])
    create index(:events, [:event_type])
    create index(:events, [:inserted_at])

    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :stream_id, :string, null: false
      add :stream_version, :integer, null: false
      add :snapshot_type, :string, null: false
      add :data, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:snapshots, [:stream_id, :stream_version])
    create index(:snapshots, [:stream_id])
  end
end
