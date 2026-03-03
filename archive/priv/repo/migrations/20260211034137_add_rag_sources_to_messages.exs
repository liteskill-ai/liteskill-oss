defmodule Liteskill.Repo.Migrations.AddRagSourcesToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :rag_sources, :map
    end
  end
end
