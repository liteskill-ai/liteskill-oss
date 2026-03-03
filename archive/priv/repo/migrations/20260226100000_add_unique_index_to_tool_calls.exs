defmodule Liteskill.Repo.Migrations.AddUniqueIndexToToolCalls do
  use Ecto.Migration

  def change do
    drop index(:tool_calls, [:tool_use_id])
    create unique_index(:tool_calls, [:tool_use_id])
  end
end
