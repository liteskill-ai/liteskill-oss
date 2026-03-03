defmodule Liteskill.Repo.Migrations.AddLastActiveAtIndexToUserSessions do
  use Ecto.Migration

  def change do
    create index(:user_sessions, [:last_active_at])
  end
end
