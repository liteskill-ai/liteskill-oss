defmodule Liteskill.Repo.Migrations.AddToolConfigToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :tool_config, :map
    end
  end
end
