defmodule Liteskill.Repo.Migrations.AddErrorMessageToRagDocuments do
  use Ecto.Migration

  def change do
    alter table(:rag_documents) do
      add :error_message, :text
    end
  end
end
