defmodule Liteskill.Repo.Migrations.AddModelLimitsToLlmModels do
  use Ecto.Migration

  def change do
    alter table(:llm_models) do
      add :context_window, :integer
      add :max_output_tokens, :integer
    end
  end
end
