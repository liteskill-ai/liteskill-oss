defmodule Liteskill.Repo.Migrations.AddCostPerMillionToLlmModels do
  use Ecto.Migration

  def change do
    alter table(:llm_models) do
      add :input_cost_per_million, :decimal
      add :output_cost_per_million, :decimal
    end
  end
end
