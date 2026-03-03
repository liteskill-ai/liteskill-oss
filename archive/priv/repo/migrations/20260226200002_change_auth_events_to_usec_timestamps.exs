defmodule Liteskill.Repo.Migrations.ChangeAuthEventsToUsecTimestamps do
  use Ecto.Migration

  def change do
    alter table(:auth_events) do
      modify :inserted_at, :utc_datetime_usec, from: :utc_datetime
    end
  end
end
