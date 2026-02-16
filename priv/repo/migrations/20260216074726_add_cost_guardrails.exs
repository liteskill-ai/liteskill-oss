defmodule Liteskill.Repo.Migrations.AddCostGuardrails do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :cost_limit, :decimal
    end

    alter table(:server_settings) do
      add :default_mcp_run_cost_limit, :decimal, default: 1.0
    end
  end
end
